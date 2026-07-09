(function() {
  'use strict';

  if (
    typeof window.GoodAnalytics !== 'undefined' &&
    (window.GoodAnalytics._initialized ||
      window.GoodAnalytics._spaNavigationSetup ||
      window.GoodAnalytics._engagementSetup)
  ) {
    console.warn('GoodAnalytics: detected duplicate snippet load; skipping init');
    return;
  }

  var GA = {
    config: {
      endpoint: '/ga/t',
      cookieName: '_ga_good',
      identityStorageKey: '_ga_good_id',
      anonCookieName: '_ga_anon',
      clientAnonymousId: false,
      clientAnonCookieName: '_ga_good_anon',
      anonStorageKey: '_ga_good_anon_id',
      fingerprintStorageKey: '_ga_good_fp',
      refCookieName: '_ga_ref',
      cookieDays: 90,
      queryParam: 'ga_id',
      viaParam: 'via',
      refParam: 'ref',
      cleanUrl: true,
      dedupWindow: 30 * 60 * 1000, // 30 minutes
      engagement: true,
      engagementThrottleMs: 3000,
      autoSpaNavigation: true,
      workspaceId: null
    },

    /**
     * Initializes tracking.
     *
     * Options:
     * - endpoint: tracking endpoint prefix, usually "/ga/t"
     * - autoSpaNavigation: when false, disables automatic pageviews for
     *   hashchange, pushState, replaceState, and popstate navigation
     *
     * Each beacon includes a fresh UUIDv4 event_id so host applications can
     * deduplicate retried beacons before forwarding them to the event recorder.
     */
    init: function(userConfig) {
      if (this._initialized) return this;
      this._initialized = true;

      if (userConfig) {
        for (var key in userConfig) {
          if (userConfig.hasOwnProperty(key)) {
            this.config[key] = userConfig[key];
          }
        }
      }

      // Check for ga_id from server redirect
      var gaId = this.getParam(this.config.queryParam);
      if (gaId) {
        this.setIdentity(gaId);
        if (this.config.cleanUrl) this.cleanUrl([this.config.queryParam]);
      }

      var self = this;
      this._fingerprintReconcileSent = false;
      this._onFingerprintReady = function() {
        self._sendFingerprintReconcile();
      };

      // Check for ?via= or ?ref= (client-side click tracking)
      var via = this.getParam(this.config.viaParam) || this.getParam(this.config.refParam);
      if (via && !gaId) {
        if (!this._isDuplicateClick(via)) {
          this.trackClientClick(via);
        }
      }

      // Initialize modules registered before init (idempotent with late use).
      this._initedModules = this._initedModules || [];
      var modules = this._modules || [];
      for (var i = 0; i < modules.length; i++) {
        this._initModule(modules[i]);
      }

      // Establish a durable client anonymous id when enabled (static/SaaS deploys
      // with no server-side _ga_anon cookie). Must run before the first beacon.
      if (this.config.clientAnonymousId) this._ensureAnonymousId();

      // Hydrate a cached fingerprint synchronously so a returning visitor's first
      // pageview carries it (the live ThumbmarkJS compute is async and usually
      // resolves after the pageview beacon). First-ever visits reconcile later.
      this._hydrateFingerprint();

      // Precomputed string fingerprint must apply before the first pageview so
      // the initial beacon includes it. Boolean true self-loads async below.
      if (typeof this.config.fingerprint === 'string' && this.config.fingerprint) {
        this.setFingerprint(this.config.fingerprint);
      }

      // Auto-track pageview after init
      if (this.config.autoPageview !== false) {
        this.track('pageview');
      }

      this._setupSpaNavigation();

      if (this.config.engagement !== false) {
        this._setupEngagement();
      }

      // fingerprint: true self-loads Thumbmark from the tracking host (non-blocking).
      if (this.config.fingerprint === true) {
        this._ensureFingerprintModule();
      }

      return this;
    },

    // Supply a browser fingerprint (e.g. from ThumbmarkJS) as a weak identity
    // signal. Safe to call after init when the fingerprint resolves async; it
    // reconciles the fingerprint to the current visitor. No-ops after forget()
    // until a full page reload (suppress is in-memory only).
    setFingerprint: function(fp) {
      if (this._suppressFingerprint) return;
      if (!fp || this._fingerprint === fp) return;
      this._fingerprint = fp;
      // Cache so the next page load can hydrate it synchronously before the pageview.
      this.setStorage(this.config.fingerprintStorageKey, fp);
      if (this._onFingerprintReady) this._onFingerprintReady();
    },

    // Load a previously-cached fingerprint synchronously. Sets `_fingerprint`
    // directly (does NOT trigger a reconcile) — the value was already known.
    _hydrateFingerprint: function() {
      if (this._fingerprint) return;
      var fp = this.getStorage(this.config.fingerprintStorageKey);
      if (fp) this._fingerprint = fp;
    },

    trackClientClick: function(partnerCode) {
      var self = this;
      var payload = {
        event_id: this._uuidv4(),
        key: partnerCode,
        url: window.location.href,
        referrer: document.referrer,
        anonymous_id: this.getCookie(this.config.anonCookieName)
      };
      if (this._fingerprint) payload.fingerprint = this._fingerprint;
      if (this.config.workspaceId) payload.workspace_id = this.config.workspaceId;
      this._addConnectorSignals(payload);

      fetch(this.config.endpoint + '/click', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(payload)
      })
      .then(function(resp) { return resp.json(); })
      .then(function(data) {
        if (data.ga_id) {
          self.setIdentity(data.ga_id);
        }
        // The server sets the _ga_ref cookie directly via Set-Cookie header.
        // No client-side cookie write needed — the cookie is NOT HttpOnly
        // so we can read it for beacon forwarding.
        if (self.config.cleanUrl) {
          self.cleanUrl([self.config.viaParam, self.config.refParam]);
        }
        self._markClickSeen(partnerCode);
      })
      .catch(function(e) {
        console.warn('[GoodAnalytics] Click tracking failed:', e);
      });
    },

    track: function(eventType, properties) {
      properties = properties || {};
      var payload = {
        event_id: this._uuidv4(),
        event_type: eventType,
        ga_id: this.getIdentity(),
        anonymous_id: this.getAnonymousId(),
        url: window.location.href,
        referrer: document.referrer,
        timestamp: new Date().toISOString()
      };
      for (var key in properties) {
        if (properties.hasOwnProperty(key)) {
          payload[key] = properties[key];
        }
      }
      if (this._fingerprint) payload.fingerprint = this._fingerprint;
      if (this.config.workspaceId) payload.workspace_id = this.config.workspaceId;

      // Include referral cookie token for server-side attribution
      var refCookie = this.getCookie(this.config.refCookieName);
      if (refCookie) payload._ga_ref = refCookie;

      // Forward connector browser identifiers
      this._addConnectorSignals(payload);

      var blob = new Blob([JSON.stringify(payload)], {type: 'application/json'});
      if (navigator.sendBeacon) {
        navigator.sendBeacon(this.config.endpoint + '/event', blob);
      } else {
        fetch(this.config.endpoint + '/event', {
          method: 'POST',
          body: blob,
          keepalive: true
        });
      }
    },

    trackLead: function(attrs) { this.track('lead', attrs); },
    trackSale: function(attrs) { this.track('sale', attrs); },

    setIdentity: function(gaId) {
      if (!gaId) return;
      this.setCookie(this.config.cookieName, gaId, this.config.cookieDays);
      if (this.config.useLocalStorage !== false) {
        this.setStorage(this.config.identityStorageKey, gaId);
      }
    },

    getIdentity: function() {
      var id = this.getCookie(this.config.cookieName);
      if (!id && this.config.useLocalStorage !== false) {
        id = this.getStorage(this.config.identityStorageKey);
      }
      return id;
    },

    // Mint (once) and persist a durable, client-side anonymous id. Stored in both
    // localStorage (durable) and a non-HttpOnly first-party cookie (so host
    // form/API code can read it). Uses a distinct key from the server-owned
    // _ga_anon cookie so the two never collide.
    _ensureAnonymousId: function() {
      var id = this.getStorage(this.config.anonStorageKey)
            || this.getCookie(this.config.clientAnonCookieName);
      if (!id) {
        id = this._uuidv4(); // null if no CSPRNG; skip silently
        if (id) {
          this.setStorage(this.config.anonStorageKey, id);
          this.setCookie(this.config.clientAnonCookieName, id, this.config.cookieDays);
        }
      }
      this._anonymousId = id;
    },

    getAnonymousId: function() {
      return this._anonymousId
          || this.getStorage(this.config.anonStorageKey)
          || this.getCookie(this.config.clientAnonCookieName)
          || this.getCookie(this.config.anonCookieName)
          || null;
    },

    getFingerprint: function() { return this._fingerprint || null; },

    getSignals: function() {
      return {
        ga_id: this.getIdentity(),
        anonymous_id: this.getAnonymousId(),
        fingerprint: this._fingerprint || null
      };
    },

    // Privacy purge of all client-accessible library-owned identity state.
    // Does NOT attempt to clear the server-owned HttpOnly _ga_anon cookie.
    // Suppresses setFingerprint for the rest of this page lifecycle (in-memory
    // only; a full reload lifts the suppress automatically).
    forget: function() {
      this.deleteCookie(this.config.cookieName);
      this.deleteCookie(this.config.refCookieName);
      this.deleteCookie(this.config.clientAnonCookieName);
      // Intentionally do not touch anonCookieName (_ga_anon) — server-owned HttpOnly.
      try { window.localStorage.removeItem(this.config.identityStorageKey); } catch(e) {}
      try { window.localStorage.removeItem(this.config.fingerprintStorageKey); } catch(e) {}
      try { window.localStorage.removeItem(this.config.anonStorageKey); } catch(e) {}
      this._clearClickDedup();
      this._fingerprint = null;
      this._anonymousId = null;
      this._fingerprintReconcileSent = false;
      this._suppressFingerprint = true;
    },

    // Clear client-side click dedup keys (_ga_click_*) from sessionStorage.
    _clearClickDedup: function() {
      try {
        var ss = window.sessionStorage;
        if (!ss) return;
        var toRemove = [];
        for (var i = 0; i < ss.length; i++) {
          var key = ss.key(i);
          if (key && key.indexOf('_ga_click_') === 0) toRemove.push(key);
        }
        for (var j = 0; j < toRemove.length; j++) ss.removeItem(toRemove[j]);
      } catch (e) {}
    },

    _sendFingerprintReconcile: function() {
      if (this._fingerprintReconcileSent) return;
      var gaId = this.getIdentity();
      var anonId = this.getAnonymousId();
      // Need the fingerprint plus at least one stable id to attach it to. This
      // fires for anon-only visitors too (no ga_id), so a pageview-created
      // visitor still accumulates its fingerprint. Never fingerprint-only.
      if (!this._fingerprint || (!gaId && !anonId)) return;

      this._fingerprintReconcileSent = true;

      var payload = {
        event_id: this._uuidv4(),
        event_type: 'custom',
        event_name: 'fingerprint_reconcile',
        reconcile_only: true,
        ga_id: gaId,
        anonymous_id: anonId,
        fingerprint: this._fingerprint,
        url: window.location.href,
        referrer: document.referrer,
        timestamp: new Date().toISOString(),
        properties: { reconcile_only: true }
      };
      if (this.config.workspaceId) payload.workspace_id = this.config.workspaceId;

      var blob = new Blob([JSON.stringify(payload)], {type: 'application/json'});
      if (navigator.sendBeacon) {
        navigator.sendBeacon(this.config.endpoint + '/event', blob);
      } else {
        fetch(this.config.endpoint + '/event', {
          method: 'POST',
          body: blob,
          keepalive: true
        });
      }
    },

    // Cookie helpers
    setCookie: function(n, v, d) {
      var e = new Date();
      e.setTime(e.getTime() + d * 864e5);
      var secure = window.location.protocol === 'https:' ? ';Secure' : '';
      document.cookie = n + '=' + encodeURIComponent(v) +
        ';expires=' + e.toUTCString() +
        ';path=/;SameSite=Lax' + secure;
    },

    getCookie: function(n) {
      var escaped = String(n).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      var m = document.cookie.match(new RegExp('(^| )' + escaped + '=([^;]+)'));
      return m ? decodeURIComponent(m[2]) : null;
    },

    // Must mirror setCookie attributes (path/SameSite/Secure) so browsers will
    // expire the cookie. Without Secure+SameSite on HTTPS, forget() can leave
    // identity cookies in place.
    deleteCookie: function(n) {
      var secure = window.location.protocol === 'https:' ? ';Secure' : '';
      document.cookie = n + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT' +
        ';path=/;SameSite=Lax' + secure;
    },

    setStorage: function(key, value) {
      try {
        window.localStorage.setItem(key, value);
      } catch (e) {}
    },

    getStorage: function(key) {
      try {
        return window.localStorage.getItem(key);
      } catch (e) {
        return null;
      }
    },

    // URL helpers
    getParam: function(n) {
      return new URLSearchParams(window.location.search).get(n);
    },

    cleanUrl: function(params) {
      var u = new URL(window.location);
      var changed = false;
      for (var i = 0; i < params.length; i++) {
        if (u.searchParams.has(params[i])) {
          u.searchParams.delete(params[i]);
          changed = true;
        }
      }
      if (changed) window.history.replaceState({}, '', u.toString());
    },

    // Module system: register optional modules. Modules registered before
    // init() run during init; modules registered after init() init immediately.
    // Dedupes by module object reference (same object only; two literals double-init).
    use: function(m) {
      if (!m) return this;
      this._modules = this._modules || [];
      this._initedModules = this._initedModules || [];
      if (this._modules.indexOf(m) === -1) {
        this._modules.push(m);
      }
      if (this._initialized) {
        this._initModule(m);
      }
      return this;
    },

    _initModule: function(m) {
      if (!m || !m.init) return;
      this._initedModules = this._initedModules || [];
      if (this._initedModules.indexOf(m) !== -1) return;
      this._initedModules.push(m);
      m.init(this);
    },

    // Strict match for the core library script filename (not substring "good-analytics").
    _isCoreScriptSrc: function(src) {
      return !!(src && /\/good-analytics(?:\.min)?\.js(?:[?#]|$)/i.test(src));
    },

    // Match thumbmark.js only (not vendor/thumbmark.umd.js).
    _isThumbmarkScriptSrc: function(src) {
      return !!(src && /\/thumbmark\.js(?:[?#]|$)/i.test(src));
    },

    // Derive the JS base path from the loaded good-analytics.js script src
    // (cross-origin safe). Prefer currentScript captured at load; fall back to
    // a strict filename scan; finally same-origin /ga/js.
    _scriptBaseUrl: function() {
      if (this._cachedScriptBaseUrl) return this._cachedScriptBaseUrl;

      var src = this._scriptSrc || null;
      if (!src) {
        var scripts = document.getElementsByTagName('script');
        for (var i = 0; i < scripts.length; i++) {
          if (this._isCoreScriptSrc(scripts[i].src)) {
            src = scripts[i].src;
            break;
          }
        }
      }

      var base = src ? src.replace(/\/[^\/]*$/, '') : '/ga/js';
      this._cachedScriptBaseUrl = base;
      return base;
    },

    // Non-blocking Thumbmark self-load for init({ fingerprint: true }).
    // Reuses ThumbmarkModule, an in-flight host thumbmark.js tag, or injects
    // from the tracking-host base. Clears loading state on error so a later
    // retry can run; falls back to inject when an existing tag already failed.
    _ensureFingerprintModule: function() {
      if (typeof window.ThumbmarkModule !== 'undefined') {
        this.use(window.ThumbmarkModule);
        return;
      }
      if (this._thumbmarkLoading) return;
      this._thumbmarkLoading = true;

      var self = this;
      var onReady = function() {
        self._thumbmarkLoading = false;
        if (typeof window.ThumbmarkModule !== 'undefined') {
          self.use(window.ThumbmarkModule);
        }
      };
      var onError = function() {
        self._thumbmarkLoading = false;
        console.warn('[GoodAnalytics] Failed to load thumbmark.js');
      };
      var injectFromBase = function() {
        var script = document.createElement('script');
        script.src = self._scriptBaseUrl() + '/thumbmark.js';
        script.onload = onReady;
        script.onerror = onError;
        (document.head || document.documentElement).appendChild(script);
      };

      // Prefer an explicit host-provided thumbmark.js script if already present.
      var scripts = document.getElementsByTagName('script');
      for (var i = 0; i < scripts.length; i++) {
        var existing = scripts[i];
        if (!this._isThumbmarkScriptSrc(existing.src)) continue;

        if (typeof window.ThumbmarkModule !== 'undefined') {
          onReady();
          return;
        }

        // Already finished without defining the module (failed prior load) → inject.
        var ready = existing.readyState;
        if (ready === 'complete' || ready === 'loaded' || existing._gaLoadFailed) {
          injectFromBase();
          return;
        }

        if (existing.addEventListener) {
          existing.addEventListener('load', onReady);
          existing.addEventListener('error', function() {
            // Host tag failed; try tracking-host copy instead of stuck forever.
            injectFromBase();
          });
        }
        // Script may already have finished loading before we attached listeners.
        if (typeof window.ThumbmarkModule !== 'undefined') onReady();
        return;
      }

      injectFromBase();
    },

    // Connector browser identifiers
    _connectorCookies: ['_fbp', '_fbc'],

    _addConnectorSignals: function(payload) {
      // Read connector browser identifiers from cookies
      for (var i = 0; i < this._connectorCookies.length; i++) {
        var name = this._connectorCookies[i];
        var val = this.getCookie(name);
        if (val) payload[name] = val;
      }
      // Allow explicit overrides from config or properties
      if (this.config.connectorSignals) {
        for (var key in this.config.connectorSignals) {
          if (this.config.connectorSignals.hasOwnProperty(key)) {
            payload[key] = this.config.connectorSignals[key];
          }
        }
      }
    },

    _uuidv4: function() {
      if (window.crypto && window.crypto.randomUUID) {
        return window.crypto.randomUUID();
      }

      // Without a CSPRNG the dedup key would be predictable, so the client
      // omits event_id and the server records every beacon. The server
      // treats a missing event_id as :ignored and does not dedup on it.
      if (!window.crypto || !window.crypto.getRandomValues) {
        return null;
      }

      var bytes = new Uint8Array(16);
      window.crypto.getRandomValues(bytes);

      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;

      var hex = [];
      for (var j = 0; j < 256; j++) {
        hex[j] = (j + 0x100).toString(16).slice(1);
      }

      return (
        hex[bytes[0]] + hex[bytes[1]] + hex[bytes[2]] + hex[bytes[3]] + '-' +
        hex[bytes[4]] + hex[bytes[5]] + '-' +
        hex[bytes[6]] + hex[bytes[7]] + '-' +
        hex[bytes[8]] + hex[bytes[9]] + '-' +
        hex[bytes[10]] + hex[bytes[11]] + hex[bytes[12]] + hex[bytes[13]] + hex[bytes[14]] + hex[bytes[15]]
      );
    },

    _setupSpaNavigation: function() {
      if (this.config.autoSpaNavigation === false || this._spaNavigationSetup) return;
      if (!window.history || !window.addEventListener) return;

      this._spaNavigationSetup = true;
      this._originalPushState = window.history.pushState;
      this._originalReplaceState = window.history.replaceState;
      this._lastSpaPageview = null;

      var self = this;

      window.history.pushState = function() {
        var result = self._originalPushState.apply(this, arguments);
        self._trackSpaPageview();
        return result;
      };

      window.history.replaceState = function() {
        var result = self._originalReplaceState.apply(this, arguments);
        self._trackSpaPageview();
        return result;
      };

      window.addEventListener('hashchange', function() {
        self._trackSpaPageview();
      });

      window.addEventListener('popstate', function() {
        self._trackSpaPageview();
      });
    },

    _trackSpaPageview: function() {
      var url = window.location.href;
      var now = Date.now();
      var last = this._lastSpaPageview;

      if (last && last.url === url && now - last.at < 250) {
        return;
      }

      this._lastSpaPageview = {url: url, at: now};
      this.track('pageview');
    },

    // Engagement tracking accrues active time only while the page is both
    // visible and focused, then flushes an engagement beacon on hide/unload.
    _setupEngagement: function() {
      if (this._engagementSetup) return;
      this._engagementSetup = true;

      this._engagedMs = 0;
      this._reportedMs = 0;
      this._maxScrollDepth = 0;
      this._observedScrollDepth = 0;
      this._activeSince = null;

      var self = this;

      this._isActive = function() {
        return document.visibilityState === 'visible' && document.hasFocus();
      };

      this._resumeEngagement = function() {
        if (self._activeSince === null && self._isActive()) {
          self._activeSince = Date.now();
        }
      };

      this._accrueEngagement = function() {
        if (self._activeSince !== null) {
          self._engagedMs += Date.now() - self._activeSince;
          self._activeSince = null;
        }
      };

      this._currentScrollDepth = function() {
        var doc = document.documentElement;
        var scrollable = doc.scrollHeight - doc.clientHeight;
        if (scrollable <= 0) return 100;
        var pct = Math.round((doc.scrollTop / scrollable) * 100);
        return Math.max(0, Math.min(100, pct));
      };

      this._updateScrollDepth = function() {
        var depth = self._currentScrollDepth();
        if (depth > self._observedScrollDepth) self._observedScrollDepth = depth;
      };

      this._flushEngagement = function() {
        self._accrueEngagement();
        self._updateScrollDepth();

        var depth = self._observedScrollDepth;
        var deltaMs = self._engagedMs - self._reportedMs;
        var deeper = depth > self._maxScrollDepth;

        if (deltaMs < self.config.engagementThrottleMs && !deeper) return;

        if (self._sendEngagement(Math.max(0, deltaMs), depth)) {
          if (depth > self._maxScrollDepth) self._maxScrollDepth = depth;
          self._reportedMs = self._engagedMs;
        }
      };

      this._updateScrollDepth();
      window.addEventListener('scroll', this._updateScrollDepth, false);
      document.addEventListener('visibilitychange', function() {
        if (document.visibilityState === 'hidden') {
          self._flushEngagement();
        } else {
          self._resumeEngagement();
        }
      });
      window.addEventListener('focus', this._resumeEngagement);
      window.addEventListener('blur', this._accrueEngagement);
      window.addEventListener('pagehide', this._flushEngagement);

      this._resumeEngagement();
    },

    _sendEngagement: function(engagedMs, scrollDepth) {
      var payload = {
        event_id: this._uuidv4(),
        event_type: 'engagement',
        ga_id: this.getIdentity(),
        anonymous_id: this.getAnonymousId(),
        url: window.location.href,
        engaged_ms: engagedMs,
        scroll_depth: scrollDepth,
        timestamp: new Date().toISOString()
      };
      if (this._fingerprint) payload.fingerprint = this._fingerprint;
      if (this.config.workspaceId) payload.workspace_id = this.config.workspaceId;

      var blob = new Blob([JSON.stringify(payload)], {type: 'application/json'});
      if (navigator.sendBeacon) {
        if (navigator.sendBeacon(this.config.endpoint + '/event', blob)) return true;
      }

      if (window.fetch) {
        fetch(this.config.endpoint + '/event', {
          method: 'POST',
          body: blob,
          keepalive: true
        });
        return true;
      }

      return false;
    },

    // Client-side dedup
    _isDuplicateClick: function(key) {
      try {
        var stored = sessionStorage.getItem('_ga_click_' + key);
        if (!stored) return false;
        var ts = parseInt(stored, 10);
        return (Date.now() - ts) < this.config.dedupWindow;
      } catch(e) { return false; }
    },

    _markClickSeen: function(key) {
      try {
        sessionStorage.setItem('_ga_click_' + key, Date.now().toString());
      } catch(e) {}
    }
  };

  // Capture this classic script's URL at evaluation time (most reliable base).
  if (typeof document !== 'undefined' && document.currentScript && document.currentScript.src) {
    GA._scriptSrc = document.currentScript.src;
  }

  window.GoodAnalytics = GA;
})();
