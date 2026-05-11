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
    var scriptPath = ga.config.endpoint.replace(/\/[^\/]*$/, '') + '/../ga/js/vendor/thumbmark.umd.js';
    // Use the same base path as the GA script
    scriptPath = '/ga/js/vendor/thumbmark.umd.js';

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
