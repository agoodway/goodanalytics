(function() {
  'use strict';

  if (typeof window.GoodAnalytics !== 'undefined' && window.GoodAnalytics._spaNavigationSetup) {
    console.warn('GoodAnalytics: detected duplicate snippet load; skipping init');
    return;
  }

  var GA = {
    config: {
      endpoint: '/ga/t',
      cookieName: '_ga_good',
      identityStorageKey: '_ga_good_id',
      anonCookieName: '_ga_anon',
      cookieDays: 90,
      queryParam: 'ga_id',
      viaParam: 'via',
      refParam: 'ref',
      cleanUrl: true,
      dedupWindow: 30 * 60 * 1000, // 30 minutes
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

      // Initialize modules
      var modules = this._modules || [];
      for (var i = 0; i < modules.length; i++) {
        if (modules[i].init) modules[i].init(this);
      }

      // Auto-track pageview after init
      if (this.config.autoPageview !== false) {
        this.track('pageview');
      }

      this._setupSpaNavigation();

      return this;
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
        anonymous_id: this.getCookie(this.config.anonCookieName),
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

    forget: function() {
      this.deleteCookie(this.config.cookieName);
      this.deleteCookie(this.config.anonCookieName);
      try { window.localStorage.removeItem(this.config.identityStorageKey); } catch(e) {}
    },

    _sendFingerprintReconcile: function() {
      if (this._fingerprintReconcileSent) return;
      var gaId = this.getIdentity();
      if (!gaId || !this._fingerprint) return;

      this._fingerprintReconcileSent = true;

      var payload = {
        event_id: this._uuidv4(),
        event_type: 'custom',
        event_name: 'fingerprint_reconcile',
        reconcile_only: true,
        ga_id: gaId,
        anonymous_id: this.getCookie(this.config.anonCookieName),
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
      var m = document.cookie.match(new RegExp('(^| )' + n + '=([^;]+)'));
      return m ? decodeURIComponent(m[2]) : null;
    },

    deleteCookie: function(n) {
      document.cookie = n + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
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

    // Module system
    use: function(m) {
      this._modules = this._modules || [];
      this._modules.push(m);
      return this;
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

  window.GoodAnalytics = GA;
})();
