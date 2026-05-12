/**
 * GoodAnalytics Thumbmark Module
 *
 * Uses self-hosted ThumbmarkJS to generate a stable browser fingerprint.
 * The fingerprint is used as an identity signal for visitor resolution.
 *
 * Usage:
 *   GoodAnalytics.use(ThumbmarkModule).init({ endpoint: '/ga/t' });
 */
var ThumbmarkModule = {
  init: function(ga) {
    // Derive vendor URL from this script's own origin so it works cross-origin.
    // Falls back to same-origin path for embedded Phoenix host-app integrations.
    var scriptPath;
    var scripts = document.getElementsByTagName('script');
    var currentSrc = '';
    for (var i = 0; i < scripts.length; i++) {
      if (scripts[i].src && scripts[i].src.indexOf('/ga/js/thumbmark') !== -1) {
        currentSrc = scripts[i].src;
        break;
      }
    }
    if (currentSrc) {
      scriptPath = currentSrc.replace(/\/[^\/]*$/, '/vendor/thumbmark.umd.js');
    } else {
      scriptPath = '/ga/js/vendor/thumbmark.umd.js';
    }

    var script = document.createElement('script');
    script.src = scriptPath;
    script.onload = function() {
      if (window.ThumbmarkJS && window.ThumbmarkJS.getFingerprint) {
        window.ThumbmarkJS.getFingerprint().then(function(fp) {
          ga._fingerprint = fp;
          if (ga._onFingerprintReady) ga._onFingerprintReady(fp);
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
