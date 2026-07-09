/**
 * Behavioral tests for good-analytics.js (Node harness with minimal DOM mock).
 * Run: node --test priv/static/js/test/good-analytics.behavior.mjs
 * (from core/) or via ExUnit GoodAnalytics.Core.Tracking.GoodAnalyticsJsTest.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const JS_PATH = path.resolve(__dirname, "../good-analytics.js");
const SOURCE = fs.readFileSync(JS_PATH, "utf8");
const THUMBMARK_PATH = path.resolve(__dirname, "../thumbmark.js");
const THUMBMARK_SOURCE = fs.readFileSync(THUMBMARK_PATH, "utf8");

function createLocalStorage() {
  const store = new Map();
  return {
    getItem(k) {
      return store.has(k) ? store.get(k) : null;
    },
    setItem(k, v) {
      store.set(String(k), String(v));
    },
    removeItem(k) {
      store.delete(k);
    },
    clear() {
      store.clear();
    },
    key(i) {
      return Array.from(store.keys())[i] ?? null;
    },
    get length() {
      return store.size;
    },
    _raw: store,
  };
}

function createCookieJar() {
  const cookies = new Map();
  const lastSet = [];
  return {
    get cookie() {
      return Array.from(cookies.entries())
        .map(([k, v]) => `${k}=${v}`)
        .join("; ");
    },
    set cookie(raw) {
      lastSet.push(String(raw));
      const parts = String(raw).split(";");
      const [pair] = parts;
      const eq = pair.indexOf("=");
      if (eq === -1) return;
      const name = pair.slice(0, eq).trim();
      const value = pair.slice(eq + 1).trim();
      const expires = parts.find((p) => p.trim().toLowerCase().startsWith("expires="));
      if (expires) {
        const expDate = new Date(expires.split("=").slice(1).join("=").trim());
        if (!Number.isNaN(expDate.getTime()) && expDate.getTime() <= Date.now()) {
          cookies.delete(name);
          return;
        }
      }
      cookies.set(name, value);
    },
    _raw: cookies,
    _lastSet: lastSet,
  };
}

function createScriptEl(src = "") {
  const el = {
    src,
    readyState: "",
    _gaLoadFailed: false,
    onload: null,
    onerror: null,
    _load: null,
    _error: null,
    addEventListener(type, fn) {
      if (type === "load") el._load = fn;
      if (type === "error") el._error = fn;
    },
    setAttribute() {},
    getAttribute() {
      return null;
    },
  };
  return el;
}

function createScriptList(initial = []) {
  const scripts = initial.map((src) => createScriptEl(src));
  return {
    list: scripts,
    getElementsByTagName(tag) {
      if (tag === "script") return scripts;
      return [];
    },
    createElement(tag) {
      if (tag !== "script") return {};
      return createScriptEl("");
    },
    appendChild(el) {
      scripts.push(el);
      return el;
    },
  };
}

function loadGoodAnalytics(options = {}) {
  const storage = createLocalStorage();
  const sessionStorage = createLocalStorage();
  const jar = createCookieJar();
  const head = createScriptList(
    options.scriptSrcs || ["https://track.example/ga/js/good-analytics.js"]
  );
  const beacons = [];
  const fetches = [];
  const appended = [];
  const warns = [];

  const originalAppend = head.appendChild.bind(head);
  head.appendChild = (el) => {
    appended.push(el);
    return originalAppend(el);
  };

  const document = {
    cookie: "",
    referrer: "",
    visibilityState: "visible",
    hasFocus: () => true,
    documentElement: { scrollHeight: 1000, clientHeight: 800, scrollTop: 0 },
    getElementsByTagName: head.getElementsByTagName,
    createElement: head.createElement,
    head: { appendChild: head.appendChild },
    // Simulate classic script evaluation of good-analytics.js
    currentScript: options.currentScript || {
      src: (options.scriptSrcs && options.scriptSrcs[0]) || "https://track.example/ga/js/good-analytics.js",
    },
    addEventListener() {},
  };

  Object.defineProperty(document, "cookie", {
    get: () => jar.cookie,
    set: (v) => {
      jar.cookie = v;
    },
    configurable: true,
  });

  const location = {
    href: options.locationHref || "https://app.example/",
    protocol: options.protocol || "https:",
    search: "",
    toString() {
      return this.href;
    },
  };

  const window = {
    GoodAnalytics: undefined,
    ThumbmarkModule: options.ThumbmarkModule,
    localStorage: storage,
    sessionStorage,
    location,
    history: {
      pushState() {},
      replaceState() {},
    },
    navigator: {
      sendBeacon(url, body) {
        beacons.push({ url, body: body && body.toString ? body.toString() : String(body) });
        return true;
      },
    },
    crypto: {
      randomUUID() {
        return "00000000-0000-4000-8000-000000000001";
      },
      getRandomValues(bytes) {
        for (let i = 0; i < bytes.length; i++) bytes[i] = i;
        return bytes;
      },
    },
    URL,
    URLSearchParams,
    Blob: class Blob {
      constructor(parts) {
        this._s = parts.join("");
      }
      toString() {
        return this._s;
      }
    },
    fetch(url, opts) {
      fetches.push({ url, opts });
      return Promise.resolve({
        json: async () => ({}),
      });
    },
    console: {
      warn(...args) {
        warns.push(args.map(String).join(" "));
      },
      log() {},
    },
    addEventListener() {},
    document,
  };

  window.window = window;
  const sandbox = {
    window,
    document,
    console: window.console,
    navigator: window.navigator,
    location: window.location,
    history: window.history,
    localStorage: storage,
    sessionStorage,
    URL,
    URLSearchParams,
    Blob: window.Blob,
    fetch: window.fetch,
    crypto: window.crypto,
  };

  vm.runInNewContext(SOURCE, sandbox, { filename: "good-analytics.js" });

  // After load, clear currentScript (browser behavior) unless test wants it kept
  if (!options.keepCurrentScript) {
    document.currentScript = null;
  }

  return {
    GA: window.GoodAnalytics,
    window,
    document,
    storage,
    sessionStorage,
    jar,
    beacons,
    fetches,
    appended,
    warns,
    head,
    sandbox,
  };
}

function loadThumbmarkModule(ctx) {
  // Point currentScript at thumbmark so vendor path derives correctly
  ctx.document.currentScript = {
    src: "https://track.example/ga/js/thumbmark.js",
  };
  vm.runInNewContext(THUMBMARK_SOURCE, ctx.sandbox, { filename: "thumbmark.js" });
  ctx.window.ThumbmarkModule = ctx.sandbox.ThumbmarkModule;
  ctx.document.currentScript = null;
  return ctx.window.ThumbmarkModule;
}

describe("forget()", () => {
  test("clears fingerprint, client-anon, identity/ref state; does not delete _ga_anon", () => {
    const { GA, storage, jar } = loadGoodAnalytics();

    GA.init({ endpoint: "/ga/t", autoPageview: false, engagement: false, autoSpaNavigation: false });
    GA.setIdentity("ga-id-1");
    GA.setFingerprint("fp-abc");
    GA.config.clientAnonymousId = true;
    GA._ensureAnonymousId();
    jar._raw.set("_ga_ref", "ref-token");
    jar._raw.set("_ga_anon", "server-anon"); // server-owned; must survive

    assert.equal(storage.getItem("_ga_good_fp"), "fp-abc");
    assert.ok(storage.getItem("_ga_good_anon_id") || jar._raw.has("_ga_good_anon"));
    assert.ok(storage.getItem("_ga_good_id") || jar._raw.has("_ga_good"));

    GA.forget();

    assert.equal(GA._fingerprint, null);
    assert.equal(GA._anonymousId, null);
    assert.equal(GA._fingerprintReconcileSent, false);
    assert.equal(storage.getItem("_ga_good_fp"), null);
    assert.equal(storage.getItem("_ga_good_id"), null);
    assert.equal(storage.getItem("_ga_good_anon_id"), null);
    assert.equal(jar._raw.has("_ga_good"), false);
    assert.equal(jar._raw.has("_ga_ref"), false);
    assert.equal(jar._raw.has("_ga_good_anon"), false);
    // Server-owned cookie untouched
    assert.equal(jar._raw.get("_ga_anon"), "server-anon");
    // forget must not attempt deleteCookie on anonCookieName
    assert.equal(GA.config.anonCookieName, "_ga_anon");
  });

  test("clears sessionStorage _ga_click_* dedup keys", () => {
    const { GA, sessionStorage } = loadGoodAnalytics();
    GA.init({ endpoint: "/ga/t", autoPageview: false, engagement: false, autoSpaNavigation: false });
    sessionStorage.setItem("_ga_click_abc", "123");
    sessionStorage.setItem("_ga_click_xyz", "456");
    sessionStorage.setItem("unrelated", "keep");

    GA.forget();

    assert.equal(sessionStorage.getItem("_ga_click_abc"), null);
    assert.equal(sessionStorage.getItem("_ga_click_xyz"), null);
    assert.equal(sessionStorage.getItem("unrelated"), "keep");
  });

  test("deleteCookie includes Secure and SameSite on HTTPS", () => {
    const { GA, jar } = loadGoodAnalytics({ protocol: "https:" });
    GA.init({ endpoint: "/ga/t", autoPageview: false, engagement: false, autoSpaNavigation: false });
    jar._lastSet.length = 0;
    GA.forget();
    const deletes = jar._lastSet.filter((s) => s.includes("expires=Thu, 01 Jan 1970"));
    assert.ok(deletes.length >= 1);
    for (const d of deletes) {
      assert.match(d, /SameSite=Lax/);
      assert.match(d, /Secure/);
      assert.match(d, /path=\//);
    }
  });

  test("setFingerprint is suppressed after forget until new instance (reload)", () => {
    const { GA, storage } = loadGoodAnalytics();
    GA.init({ endpoint: "/ga/t", autoPageview: false, engagement: false, autoSpaNavigation: false });
    GA.setFingerprint("fp-1");
    assert.equal(GA.getFingerprint(), "fp-1");

    GA.forget();
    GA.setFingerprint("fp-2");
    assert.equal(GA.getFingerprint(), null);
    assert.equal(storage.getItem("_ga_good_fp"), null);
    assert.equal(GA._suppressFingerprint, true);

    // Full reload = new instance without suppress flag
    const next = loadGoodAnalytics();
    next.GA.init({
      endpoint: "/ga/t",
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });
    assert.equal(next.GA._suppressFingerprint, undefined);
    next.GA.setFingerprint("fp-3");
    assert.equal(next.GA.getFingerprint(), "fp-3");
  });

  test("forget mid self-load suppresses late setFingerprint", () => {
    const calls = [];
    const ThumbmarkModule = {
      init(ga) {
        calls.push(1);
        ga.setFingerprint("late-fp");
      },
    };
    const ctx = loadGoodAnalytics();
    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });
    assert.equal(ctx.appended.length, 1);
    ctx.GA.forget();

    // Simulate thumbmark load completing after forget
    ctx.window.ThumbmarkModule = ThumbmarkModule;
    if (typeof ctx.appended[0].onload === "function") {
      ctx.appended[0].onload();
    }

    assert.equal(calls.length, 1);
    assert.equal(ctx.GA.getFingerprint(), null);
    assert.equal(ctx.storage.getItem("_ga_good_fp"), null);
    assert.equal(ctx.GA._suppressFingerprint, true);
  });
});

describe("module system", () => {
  test("late use after init initializes the module once", () => {
    const { GA } = loadGoodAnalytics();
    const calls = [];
    const mod = {
      init(ga) {
        calls.push(ga);
      },
    };

    GA.init({ endpoint: "/ga/t", autoPageview: false, engagement: false, autoSpaNavigation: false });
    assert.equal(calls.length, 0);

    GA.use(mod);
    assert.equal(calls.length, 1);
    assert.equal(calls[0], GA);

    GA.use(mod);
    assert.equal(calls.length, 1);
  });

  test("duplicate use before/after init does not double-init", () => {
    const { GA } = loadGoodAnalytics();
    const calls = [];
    const mod = {
      init() {
        calls.push(1);
      },
    };

    GA.use(mod).use(mod);
    GA.init({ endpoint: "/ga/t", autoPageview: false, engagement: false, autoSpaNavigation: false });
    assert.equal(calls.length, 1);
    GA.use(mod);
    assert.equal(calls.length, 1);
  });
});

describe("fingerprint: true self-load", () => {
  test("injects thumbmark.js from tracking host base path", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: ["https://track.example/ga/js/good-analytics.js"],
    });

    ctx.GA.init({
      endpoint: "https://track.example/ga/t",
      fingerprint: true,
      autoPageview: true,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.appended[0].src, "https://track.example/ga/js/thumbmark.js");
    // Initial pageview still sent (non-blocking)
    assert.ok(ctx.beacons.some((b) => b.url.includes("/event")));
  });

  test("same-origin relative path derives /ga/js/thumbmark.js", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: ["/ga/js/good-analytics.js"],
      currentScript: { src: "/ga/js/good-analytics.js" },
    });

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.appended[0].src, "/ga/js/thumbmark.js");
  });

  test("falls back to /ga/js when no core script is found", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: ["https://cdn.example/other-lib.js"],
      currentScript: { src: "" },
    });
    // Force empty _scriptSrc after load
    ctx.GA._scriptSrc = null;
    ctx.GA._cachedScriptBaseUrl = null;

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.appended[0].src, "/ga/js/thumbmark.js");
  });

  test("ignores decoy script whose src merely contains good-analytics substring", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: [
        "https://cdn.example/docs/good-analytics-guide.js",
        "https://track.example/ga/js/good-analytics.js",
      ],
      currentScript: { src: "https://track.example/ga/js/good-analytics.js" },
    });

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended[0].src, "https://track.example/ga/js/thumbmark.js");
  });

  test("string fingerprint does not self-load; sets before first pageview", () => {
    const ctx = loadGoodAnalytics();
    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: "precomputed-hash",
      autoPageview: true,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 0);
    assert.equal(ctx.GA.getFingerprint(), "precomputed-hash");
    const pageview = ctx.beacons.find((b) => b.url.includes("/event"));
    assert.ok(pageview);
    assert.match(pageview.body, /precomputed-hash/);
  });

  test("uses existing ThumbmarkModule without injecting script", () => {
    const calls = [];
    const ThumbmarkModule = {
      init(ga) {
        calls.push(ga);
      },
    };
    const ctx = loadGoodAnalytics({ ThumbmarkModule });

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 0);
    assert.equal(calls.length, 1);

    // Mixed: explicit use + fingerprint true does not double-init
    ctx.GA.use(ThumbmarkModule);
    assert.equal(calls.length, 1);
  });

  test("explicit use + fingerprint true does not double-init", () => {
    const calls = [];
    const ThumbmarkModule = {
      init() {
        calls.push(1);
      },
    };
    const ctx = loadGoodAnalytics({ ThumbmarkModule });

    ctx.GA.use(ThumbmarkModule).init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(calls.length, 1);
  });

  test("explicit real ThumbmarkModule plus fingerprint true appends vendor and generates fingerprint once", async () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: [
        "https://track.example/ga/js/good-analytics.js",
        "https://track.example/ga/js/thumbmark.js",
      ],
    });
    const ThumbmarkModule = loadThumbmarkModule(ctx);
    let fingerprintCalls = 0;
    ctx.window.ThumbmarkJS = {
      getFingerprint() {
        fingerprintCalls += 1;
        return Promise.resolve("fp-real-thumbmark");
      },
    };

    ctx.GA.use(ThumbmarkModule).init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });
    ctx.GA.use(ThumbmarkModule);

    // Reuses existing ThumbmarkJS — no vendor inject; promise settles on microtask
    await Promise.resolve();
    assert.equal(fingerprintCalls, 1);
    assert.equal(ctx.GA.getFingerprint(), "fp-real-thumbmark");
  });

  test("thumbmark load failure is non-blocking for pageview and clears loading flag", () => {
    const ctx = loadGoodAnalytics();
    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: true,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.GA._thumbmarkLoading, true);
    if (typeof ctx.appended[0].onerror === "function") {
      ctx.appended[0].onerror();
    }

    assert.ok(ctx.beacons.some((b) => b.url.includes("/event")));
    assert.equal(ctx.GA.getFingerprint(), null);
    assert.equal(ctx.GA._thumbmarkLoading, false);
    assert.ok(ctx.warns.some((w) => /Failed to load thumbmark\.js/.test(w)));
  });

  test("does not inject duplicate thumbmark.js when already present and in-flight", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: [
        "https://track.example/ga/js/good-analytics.js",
        "https://track.example/ga/js/thumbmark.js",
      ],
    });

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 0);
    // Fire load on existing tag after defining module
    const existing = ctx.head.list.find((s) => /thumbmark\.js/.test(s.src));
    assert.ok(existing);
    const calls = [];
    ctx.window.ThumbmarkModule = {
      init() {
        calls.push(1);
      },
    };
    if (typeof existing._load === "function") existing._load();
    assert.equal(calls.length, 1);
    assert.equal(ctx.GA._thumbmarkLoading, false);
  });

  test("failed existing thumbmark tag falls back to inject from tracking host", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: [
        "https://track.example/ga/js/good-analytics.js",
        "https://broken.example/thumbmark.js",
      ],
    });
    // Mark host tag as already failed
    const existing = ctx.head.list.find((s) => /thumbmark\.js/.test(s.src));
    existing._gaLoadFailed = true;
    existing.readyState = "complete";

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.appended[0].src, "https://track.example/ga/js/thumbmark.js");
  });

  test("existing tag error event falls back to inject", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: [
        "https://track.example/ga/js/good-analytics.js",
        "https://host.example/ga/js/thumbmark.js",
      ],
    });

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 0);
    const existing = ctx.head.list.find((s) => /thumbmark\.js/.test(s.src));
    if (typeof existing._error === "function") existing._error();
    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.appended[0].src, "https://track.example/ga/js/thumbmark.js");
  });

  test("does not treat vendor/thumbmark.umd.js as host thumbmark.js", () => {
    const ctx = loadGoodAnalytics({
      scriptSrcs: [
        "https://track.example/ga/js/good-analytics.js",
        "https://track.example/ga/js/vendor/thumbmark.umd.js",
      ],
    });

    ctx.GA.init({
      endpoint: "/ga/t",
      fingerprint: true,
      autoPageview: false,
      engagement: false,
      autoSpaNavigation: false,
    });

    assert.equal(ctx.appended.length, 1);
    assert.equal(ctx.appended[0].src, "https://track.example/ga/js/thumbmark.js");
  });
});
