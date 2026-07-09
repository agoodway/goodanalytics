/**
 * GoodAnalytics Thumbmark Module
 *
 * Uses self-hosted ThumbmarkJS to generate a stable browser fingerprint.
 * The fingerprint is used as an identity signal for visitor resolution.
 *
 * Usage:
 *   GoodAnalytics.use(ThumbmarkModule).init({ endpoint: '/ga/t' });
 *   // or init({ fingerprint: true }) which self-loads this module
 */
var ThumbmarkModule = {
  init: function(ga) {
    // Derive vendor URL from this script's own origin so it works cross-origin.
    // Falls back to same-origin path for embedded Phoenix host-app integrations.
    var scriptPath;
    var currentSrc =
      (typeof document !== 'undefined' &&
        document.currentScript &&
        document.currentScript.src) ||
      '';

    if (!currentSrc) {
      var scripts = document.getElementsByTagName('script');
      // Match thumbmark.js only (not vendor/thumbmark.umd.js).
      var re = /\/thumbmark\.js(?:[?#]|$)/i;
      for (var i = 0; i < scripts.length; i++) {
        if (scripts[i].src && re.test(scripts[i].src)) {
          currentSrc = scripts[i].src;
          break;
        }
      }
    }

    if (currentSrc) {
      scriptPath = currentSrc.replace(/\/[^\/]*$/, '/vendor/thumbmark.umd.js');
    } else {
      scriptPath = '/ga/js/vendor/thumbmark.umd.js';
    }

    // Reuse a host-provided ThumbmarkJS if already present.
    if (window.ThumbmarkJS && window.ThumbmarkJS.getFingerprint) {
      window.ThumbmarkJS.getFingerprint()
        .then(function(fp) {
          if (ga.setFingerprint) ga.setFingerprint(fp);
        })
        .catch(function(e) {
          console.warn('[GoodAnalytics] Fingerprint generation failed:', e);
        });
      return;
    }

    var script = document.createElement('script');
    script.src = scriptPath;
    script.onload = function() {
      if (window.ThumbmarkJS && window.ThumbmarkJS.getFingerprint) {
        window.ThumbmarkJS.getFingerprint().then(function(fp) {
          // Single entry point: caches the fingerprint and reconciles it to the
          // current visitor (incl. anon-only visitors after the pageview fired).
          if (ga.setFingerprint) ga.setFingerprint(fp);
        }).catch(function(e) {
          console.warn('[GoodAnalytics] Fingerprint generation failed:', e);
        });
      }
    };
    script.onerror = function() {
      console.warn('[GoodAnalytics] Failed to load ThumbmarkJS');
    };
    document.head.appendChild(script);
  }
};
