import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'facebook_auth_service.dart';
import 'social_backend_service.dart';

/// Secure JavaScript Bridge Service managing bidirectional communication
/// between the Pastel website (inside WebView) and Flutter Native authentication.
class SocialBridgeService {
  SocialBridgeService._internal();
  static final SocialBridgeService instance = SocialBridgeService._internal();

  WebViewController? _webViewController;
  String? _activeRequestId;
  Completer<void>? _currentAuthCompleter;

  void attachController(WebViewController controller) {
    _webViewController = controller;
  }

  /// Client-side JavaScript helper injected on every page load.
  /// Defines `window.PastelNative` and dispatches requests through the channel.
  static const String kPastelNativeInjectionJs = '''
(function() {
  if (window.PastelNativeInitialized) return;
  window.PastelNativeInitialized = true;

  window.PastelNative = {
    isAvailable: true,
    version: 1,

    // Initiates social account connection
    connectSocialAccount: function(provider, customRequestId) {
      var reqId = customRequestId || 'req_' + Date.now() + '_' + Math.random().toString(36).substr(2, 6);
      if (window.PastelNativeChannel) {
        window.PastelNativeChannel.postMessage(JSON.stringify({
          version: 1,
          action: 'connect_social_account',
          provider: provider || 'facebook',
          requestId: reqId
        }));
      } else {
        console.warn('[PastelNative] PastelNativeChannel not available.');
      }
      return reqId;
    },

    // Cancels in-flight authorization
    cancelAuthorization: function(requestId) {
      if (window.PastelNativeChannel) {
        window.PastelNativeChannel.postMessage(JSON.stringify({
          version: 1,
          action: 'cancel_authorization',
          requestId: requestId
        }));
      }
    },

    // Queries connection status
    getConnectionStatus: function(customRequestId) {
      var reqId = customRequestId || 'req_status_' + Date.now();
      if (window.PastelNativeChannel) {
        window.PastelNativeChannel.postMessage(JSON.stringify({
          version: 1,
          action: 'get_connection_status',
          requestId: reqId
        }));
      }
      return reqId;
    }
  };

  // Dispatch custom event to notify website that native bridge is ready
  window.dispatchEvent(new CustomEvent('PastelNativeReady', { detail: { version: 1 } }));
})();
''';

  /// Processes messages received from the `PastelNativeChannel` JavaScript Channel.
    /// Directly starts native Meta login without waiting for a JS message.
  /// Used when an OAuth navigation attempt is intercepted from the WebView.
  Future<void> startDirectFacebookLogin({String provider = 'facebook'}) async {
    final String reqId = 'direct_${DateTime.now().millisecondsSinceEpoch}';
    await _handleConnectAction(reqId, provider);
  }

  Future<void> handleJavascriptMessage(
    String rawMessage,
    String? currentUrl,
  ) async {
    // 1. Origin validation: Only allow messages from verified pastel-eg.com domains
    if (currentUrl != null && currentUrl.isNotEmpty) {
      final Uri? uri = Uri.tryParse(currentUrl);
      if (uri == null || (!uri.host.contains('pastel-eg.com') && !uri.host.contains('localhost'))) {
        if (kDebugMode) {
          debugPrint('[SocialBridgeService] Rejected message from unverified origin: $currentUrl');
        }
        return;
      }
    }

    // 2. Strict JSON parsing and schema validation
    Map<String, dynamic> data;
    try {
      final parsed = jsonDecode(rawMessage);
      if (parsed is! Map<String, dynamic>) {
        _dispatchError('invalid_request', 'unknown', 'invalid_request', 'Payload must be a JSON object.');
        return;
      }
      data = parsed;
    } catch (e) {
      _dispatchError('invalid_json', 'unknown', 'invalid_request', 'Malformed JSON payload.');
      return;
    }

    final int version = data['version'] is int ? data['version'] : 1;
    final String? action = data['action']?.toString();
    final String? provider = data['provider']?.toString()?.toLowerCase();
    final String requestId = data['requestId']?.toString() ?? 'req_${DateTime.now().millisecondsSinceEpoch}';

    if (version != 1 || action == null || action.isEmpty) {
      _dispatchError(requestId, provider ?? 'unknown', 'invalid_request', 'Missing or unsupported bridge version/action.');
      return;
    }

    // 3. Action Routing
    switch (action) {
      case 'connect_social_account':
        await _handleConnectAction(requestId, provider ?? 'facebook');
        break;

      case 'cancel_authorization':
        _handleCancelAction(requestId, provider ?? 'unknown');
        break;

      case 'get_connection_status':
        await _handleStatusAction(requestId);
        break;

      default:
        _dispatchError(requestId, provider ?? 'unknown', 'unsupported', 'Action "$action" is not supported.');
    }
  }

  /// Handles `connect_social_account` for facebook/instagram
  Future<void> _handleConnectAction(String requestId, String provider) async {
    if (provider != 'facebook' && provider != 'instagram') {
      _dispatchError(requestId, provider, 'unsupported', 'Provider "$provider" is not supported.');
      return;
    }

    // Duplicate request prevention: reject if another auth flow is active
    if (_currentAuthCompleter != null && !_currentAuthCompleter!.isCompleted) {
      _dispatchError(requestId, provider, 'duplicate_request', 'An authorization request is already in progress.');
      return;
    }

    _activeRequestId = requestId;
    final Completer<void> completer = Completer<void>();
    _currentAuthCompleter = completer;

    // Set 60-second timeout guard
    final Timer timeoutTimer = Timer(const Duration(seconds: 60), () {
      if (!completer.isCompleted) {
        completer.complete();
        _dispatchError(requestId, provider, 'timeout', 'Authorization request timed out.');
      }
    });

    try {
      // 1. Perform Native Facebook Login via SDK
      final FacebookAuthResult authResult = await FacebookAuthService.instance.login();

      if (completer.isCompleted) return;

      if (!authResult.isSuccess) {
        final String mappedStatus;
        switch (authResult.status) {
          case FacebookAuthStatus.cancelled:
            mappedStatus = 'cancelled';
            break;
          case FacebookAuthStatus.permissionDenied:
            mappedStatus = 'permission_denied';
            break;
          default:
            mappedStatus = 'authentication_failed';
        }

        _dispatchResult({
          'version': 1,
          'requestId': requestId,
          'provider': provider,
          'status': mappedStatus,
          'errorMessage': authResult.errorMessage ?? 'فشلت عملية المصادقة.',
        });
        return;
      }

      // 2. Execute authenticated token exchange inside WebView session (includes HttpOnly session cookies)
      if (_webViewController != null) {
        final token = authResult.accessToken!;
        final permissionsJson = jsonEncode(authResult.grantedPermissions.toList());
        final syncJs = '''
(function() {
  function getCsrf() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    if (meta && meta.getAttribute('content')) return meta.getAttribute('content');
    var m = document.cookie.match(/XSRF-TOKEN=([^;]+)/);
    return m ? decodeURIComponent(m[1]) : '';
  }
  var csrf = getCsrf();
  var payload = JSON.stringify({
    provider: 'facebook',
    access_token: ${jsonEncode(token)},
    granted_permissions: $permissionsJson,
    device_platform: 'android'
  });

  var primaryUrl = '/provider/automation-settings/provider/social-connections/meta/connect-token';
  var fallbackUrl = '/ar/mobile/social/meta/connect-token';

  function sendReq(url, onFail) {
    fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-TOKEN': csrf,
        'X-Requested-With': 'XMLHttpRequest'
      },
      body: payload,
      credentials: 'include'
    }).then(function(res) {
      if (res.ok) {
        setTimeout(function() { window.location.reload(); }, 300);
      } else if (onFail) {
        onFail();
      } else {
        res.json().then(function(d) {
          console.warn('[PastelNative] Server error:', d);
        }).catch(function() {});
      }
    }).catch(function(err) {
      if (onFail) onFail();
    });
  }

  sendReq(primaryUrl, function() {
    sendReq(fallbackUrl, null);
  });
})();
''';
        await _webViewController!.runJavaScript(syncJs);
      }

      // 3. Parallel direct Dart exchange
      final String csrfToken = await _extractCsrfTokenFromWebView();
      final String cookieHeader = await _extractCookiesFromWebView();

      final BackendSocialConnectResult backendResult = await SocialBackendService.instance.connectMetaToken(
        accessToken: authResult.accessToken!,
        grantedPermissions: authResult.grantedPermissions,
        csrfToken: csrfToken,
        cookieHeader: cookieHeader,
      );

      if (completer.isCompleted) return;

      // 4. Dispatch final clean response to WebView without ever returning the access token!
      _dispatchResult(backendResult.toBridgePayload(requestId, provider));
      if (backendResult.isSuccess && _webViewController != null) {
        Future.delayed(const Duration(milliseconds: 500), () {
          _webViewController?.reload();
        });
      }
    } catch (e) {
      if (!completer.isCompleted) {
        _dispatchError(requestId, provider, 'backend_error', 'Internal error: ${e.toString()}');
      }
    } finally {
      timeoutTimer.cancel();
      if (!completer.isCompleted) completer.complete();
      _activeRequestId = null;
      _currentAuthCompleter = null;
    }
  }

  /// Handles `cancel_authorization`
  void _handleCancelAction(String requestId, String provider) {
    if (_activeRequestId == requestId && _currentAuthCompleter != null && !_currentAuthCompleter!.isCompleted) {
      _currentAuthCompleter!.complete();
      _activeRequestId = null;
      _currentAuthCompleter = null;
      _dispatchResult({
        'version': 1,
        'requestId': requestId,
        'provider': provider,
        'status': 'cancelled',
        'message': 'تم إلغاء العملية.',
      });
    }
  }

  /// Handles `get_connection_status`
  Future<void> _handleStatusAction(String requestId) async {
    // Notify the WebView to query its standard endpoint or return stored status
    _dispatchResult({
      'version': 1,
      'requestId': requestId,
      'provider': 'facebook',
      'status': 'success',
      'action': 'refresh_status',
    });
  }

  /// Dispatches the final result back to the website via `window.onSocialConnectionResult(...)`
  void _dispatchResult(Map<String, dynamic> payload) {
    if (_webViewController == null) return;

    // SECURITY CHECK: Verify that NO access token or secret is in payload
    final sanitized = Map<String, dynamic>.from(payload);
    sanitized.remove('access_token');
    sanitized.remove('accessToken');
    sanitized.remove('token');
    sanitized.remove('secret');

    final String jsonStr = jsonEncode(sanitized);
    final String jsCode = '''
(function() {
  if (typeof window.onSocialConnectionResult === 'function') {
    try {
      window.onSocialConnectionResult($jsonStr);
    } catch(e) {
      console.error('[PastelNative] Error in onSocialConnectionResult handler:', e);
    }
  }
  window.dispatchEvent(new CustomEvent('PastelSocialConnectionResult', { detail: $jsonStr }));
})();
''';

    _webViewController!.runJavaScript(jsCode).catchError((err) {
      if (kDebugMode) {
        debugPrint('[SocialBridgeService] runJavaScript error: $err');
      }
    });
  }

  void _dispatchError(String requestId, String provider, String status, String message) {
    _dispatchResult({
      'version': 1,
      'requestId': requestId,
      'provider': provider,
      'status': status,
      'errorMessage': message,
    });
  }

  Future<String> _extractCsrfTokenFromWebView() async {
    if (_webViewController == null) return '';
    try {
      final res = await _webViewController!.runJavaScriptReturningResult('''
(function() {
  var meta = document.querySelector('meta[name="csrf-token"]');
  if (meta && meta.getAttribute('content')) return meta.getAttribute('content');
  var m = document.cookie.match(/XSRF-TOKEN=([^;]+)/);
  if (m) return decodeURIComponent(m[1]);
  return '';
})()
''');
      return res.toString().replaceAll('"', '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<String> _extractCookiesFromWebView() async {
    if (_webViewController == null) return '';
    try {
      final res = await _webViewController!.runJavaScriptReturningResult('document.cookie');
      return res.toString().replaceAll('"', '').trim();
    } catch (_) {
      return '';
    }
  }
}
