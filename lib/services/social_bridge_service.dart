import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'facebook_auth_service.dart';

/// Service coordinating communication between the Pastel Website (WebView)
/// and Native Social Authentication SDKs.
///
/// Protocol Specification (v1):
/// - Incoming JS Channel: `PastelNativeChannel`
/// - Outgoing JS Callback: `window.onSocialConnectionResult(payload)`
/// - Outgoing DOM CustomEvent: `window.dispatchEvent(new CustomEvent('PastelSocialConnectionResult', { detail: payload }))`
class SocialBridgeService {
  SocialBridgeService._internal();
  static final SocialBridgeService instance = SocialBridgeService._internal();

  WebViewController? _webViewController;
  Completer<void>? _currentAuthCompleter;
  Completer<Map<String, dynamic>>? _pendingWebViewSyncCompleter;
  String? _activeRequestId;

  void attachController(WebViewController controller) {
    _webViewController = controller;
  }

  /// JavaScript helper injected at page start/finish so the website can
  /// easily detect that it is running inside the native Pastel Flutter app
  /// and invoke `window.PastelNative.connectSocialAccount('facebook')`.
  static const String kPastelNativeInjectionJs = '''
(function() {
  if (window.PastelNative && window.PastelNative._initialized) return;

  window.PastelNative = {
    _initialized: true,
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

  /// Directly starts native Meta login without waiting for a JS message.
  /// Used when an OAuth navigation attempt is intercepted from the WebView.
  Future<void> startDirectFacebookLogin({String provider = 'facebook'}) async {
    final String reqId = 'direct_${DateTime.now().millisecondsSinceEpoch}';
    await _handleConnectAction(reqId, provider);
  }

  /// Processes messages received from the `PastelNativeChannel` JavaScript Channel.
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
        await _dispatchError('invalid_request', 'unknown', 'invalid_request', 'Payload must be a JSON object.');
        return;
      }
      data = parsed;
    } catch (e) {
      await _dispatchError('invalid_json', 'unknown', 'invalid_request', 'Malformed JSON payload.');
      return;
    }

    final int version = data['version'] is int ? data['version'] : 1;
    final String? action = data['action']?.toString();
    final String? provider = data['provider']?.toString().toLowerCase();
    final String requestId = data['requestId']?.toString() ?? 'req_${DateTime.now().millisecondsSinceEpoch}';

    if (version != 1 || action == null || action.isEmpty) {
      await _dispatchError(requestId, provider ?? 'unknown', 'invalid_request', 'Missing or unsupported bridge version/action.');
      return;
    }

    // 3. Action Routing
    switch (action) {
      case 'connect_social_account':
        await _handleConnectAction(requestId, provider ?? 'facebook');
        break;
      case 'meta_sync_complete':
        // Only accept callback if it matches the currently active request ID
        // and the pending completer has not already completed (prevents stale & duplicate callbacks).
        if (requestId == _activeRequestId &&
            _pendingWebViewSyncCompleter != null &&
            !_pendingWebViewSyncCompleter!.isCompleted) {
          final completerToComplete = _pendingWebViewSyncCompleter!;
          _pendingWebViewSyncCompleter = null;
          completerToComplete.complete(data);
        }
        break;
      case 'cancel_authorization':
        await _handleCancelAction(requestId, provider ?? 'unknown');
        break;
      case 'get_connection_status':
        await _handleStatusAction(requestId);
        break;
      default:
        await _dispatchError(requestId, provider ?? 'unknown', 'unsupported', 'Action "$action" is not supported.');
    }
  }

  /// Handles `connect_social_account` for facebook/instagram
  Future<void> _handleConnectAction(String requestId, String provider) async {
    if (provider != 'facebook' && provider != 'instagram') {
      await _dispatchError(requestId, provider, 'unsupported', 'Provider "$provider" is not supported.');
      return;
    }

    // Duplicate request prevention: reject if another auth flow is active
    if (_currentAuthCompleter != null && !_currentAuthCompleter!.isCompleted) {
      await _dispatchError(requestId, provider, 'duplicate_request', 'An authorization request is already in progress.');
      return;
    }

    _activeRequestId = requestId;
    final Completer<void> completer = Completer<void>();
    _currentAuthCompleter = completer;

    // Set 60-second timeout guard
    final Timer timeoutTimer = Timer(const Duration(seconds: 60), () {
      if (!completer.isCompleted) {
        completer.complete();
        if (_pendingWebViewSyncCompleter != null && !_pendingWebViewSyncCompleter!.isCompleted) {
          final syncCompleter = _pendingWebViewSyncCompleter!;
          _pendingWebViewSyncCompleter = null;
          syncCompleter.complete({
            'success': false,
            'statusCode': 408,
            'errorType': 'timeout',
            'data': {'message': 'Authorization request timed out.'},
          });
        }
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

        await _dispatchResult({
          'version': 1,
          'requestId': requestId,
          'provider': provider,
          'status': mappedStatus,
          'errorMessage': authResult.errorMessage ?? 'فشلت عملية المصادقة.',
        });
        return;
      }

      if (_webViewController == null) {
        await _dispatchError(requestId, provider, 'backend_error', 'WebView controller is not attached.');
        return;
      }

      // 2. Execute a single canonical authenticated request inside the WebView session
      // to `/ar/mobile/social/meta/connect-token` using `fetch` with `credentials: 'include'`.
      // The WebView natively attaches the HttpOnly Laravel session cookie without JS cookie extraction.
      final String token = authResult.accessToken!;
      final String permissionsJson = jsonEncode(authResult.grantedPermissions.toList());
      final String platformStr = Platform.isAndroid ? 'android' : 'ios';

      final Completer<Map<String, dynamic>> syncCompleter = Completer<Map<String, dynamic>>();
      _pendingWebViewSyncCompleter = syncCompleter;

      final String syncJs = '''
(function() {
  var reported = false;
  function reportResult(ok, statusCode, errorType, data) {
    if (reported) return;
    reported = true;
    if (window.PastelNativeChannel) {
      window.PastelNativeChannel.postMessage(JSON.stringify({
        version: 1,
        action: 'meta_sync_complete',
        requestId: ${jsonEncode(requestId)},
        provider: ${jsonEncode(provider)},
        success: ok,
        statusCode: statusCode,
        errorType: errorType || '',
        data: data || {}
      }));
    }
  }

  function showInPageFeedback(message, isError) {
    try {
      var existing = document.getElementById('pastel-native-meta-feedback');
      if (existing) existing.remove();
      var banner = document.createElement('div');
      banner.id = 'pastel-native-meta-feedback';
      banner.style.cssText = 'position:fixed;top:16px;left:16px;right:16px;z-index:999999;padding:14px 18px;border-radius:10px;font-family:sans-serif;font-size:14px;line-height:1.5;direction:rtl;text-align:right;box-shadow:0 8px 24px rgba(0,0,0,0.18);' +
        (isError ? 'background:#FEF2F2;color:#991B1B;border:1px solid #F87171;' : 'background:#ECFDF5;color:#065F46;border:1px solid #34D399;');
      banner.textContent = message;
      document.body.appendChild(banner);
      setTimeout(function() { if (banner.parentNode) banner.remove(); }, 8000);
    } catch (e) {}
  }

  function getPlainCsrf() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    if (meta && meta.getAttribute('content')) return meta.getAttribute('content').trim();
    var input = document.querySelector('input[name="_token"]');
    if (input && input.value) return input.value.trim();
    var livewire = document.querySelector('[data-csrf]');
    if (livewire && livewire.getAttribute('data-csrf')) return livewire.getAttribute('data-csrf').trim();
    return '';
  }

  function getXsrfCookie() {
    var m = document.cookie.match(/(?:^|;\\s*)XSRF-TOKEN=([^;]+)/);
    if (!m) return '';
    try {
      return decodeURIComponent(m[1]);
    } catch (e) {
      return m[1];
    }
  }

  var plainCsrf = getPlainCsrf();
  var xsrfCookie = getXsrfCookie();
  var headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest'
  };
  if (plainCsrf) headers['X-CSRF-TOKEN'] = plainCsrf;
  if (xsrfCookie) headers['X-XSRF-TOKEN'] = xsrfCookie;

  var bodyObj = {
    provider: ${jsonEncode(provider)},
    access_token: ${jsonEncode(token)},
    granted_permissions: $permissionsJson,
    device_platform: ${jsonEncode(platformStr)}
  };
  if (plainCsrf) bodyObj._token = plainCsrf;

  fetch('/ar/mobile/social/meta/connect-token', {
    method: 'POST',
    headers: headers,
    body: JSON.stringify(bodyObj),
    credentials: 'include'
  }).then(function(res) {
    return res.text().then(function(rawText) {
      var data = null;
      var parseOk = false;
      try {
        data = JSON.parse(rawText);
        parseOk = (data !== null && typeof data === 'object');
      } catch (e) {
        parseOk = false;
      }

      if (!parseOk) {
        var parseMsg = 'استجابة غير صالحة من السيرفر (رمز: ' + res.status + ').';
        showInPageFeedback(parseMsg, true);
        reportResult(false, res.status, 'parse_error', { message: parseMsg });
        return;
      }

      var isConfirmedConnected = res.ok && (
        data.connected === true ||
        data.is_connected === true
      );

      if (isConfirmedConnected) {
        var pageName = (data.connected_page && data.connected_page.name) ||
                       (data.connection && data.connection.page_name) || '';
        var igUser = (data.connection && data.connection.instagram_username) ||
                     (data.connected_page && data.connected_page.instagram_account && data.connected_page.instagram_account.username) || '';
        var successMsg = 'تم ربط حساب فيسبوك بنجاح';
        if (pageName) successMsg += ' (' + pageName + (igUser ? ' / @' + igUser : '') + ')';
        showInPageFeedback(successMsg, false);
        reportResult(true, res.status, '', data);
        return;
      }

      if (res.status === 422) {
        var rawErr = (data && data.message) ? String(data.message) : '';
        var msg422 = 'لم يكتمل ربط الصفحة أو حساب إنستغرام. يرجى الضغط على "ربط Facebook" ثم اختيار "Edit previous settings" (تعديل الإعدادات السابقة) وتحديد الصفحة وحساب Instagram ثم المتابعة.';
        if (rawErr && rawErr.indexOf('zero pages') === -1 && rawErr.indexOf('required page permissions') === -1) {
          msg422 = msg422 + ' (' + rawErr + ')';
        }
        showInPageFeedback(msg422, true);
        reportResult(false, 422, 'validation_error', { message: msg422, serverMessage: rawErr });
        return;
      }

      if (res.status === 401) {
        var msg401 = 'انتهت صلاحية جلسة تسجيل الدخول. يرجى إعادة تسجيل الدخول في باستيل ثم المحاولة مرة أخرى.';
        showInPageFeedback(msg401, true);
        reportResult(false, 401, 'unauthenticated', { message: msg401 });
        return;
      }

      if (res.status === 419) {
        var msg419 = 'انتهت صلاحية رمز الحماية (CSRF). يرجى تحديث الصفحة والمحاولة مرة أخرى.';
        showInPageFeedback(msg419, true);
        reportResult(false, 419, 'csrf_mismatch', { message: msg419 });
        return;
      }

      if (res.ok && !isConfirmedConnected) {
        var unconfirmedMsg = (data && data.status === 'error' && data.message)
          ? String(data.message)
          : 'لم يؤكد السيرفر اكتمال ربط الصفحة (connected=false).';
        showInPageFeedback(unconfirmedMsg, true);
        reportResult(false, res.status, 'unconfirmed_connection', { message: unconfirmedMsg });
        return;
      }

      var genericMsg = (data && data.message) ? String(data.message) : ('حدث خطأ في السيرفر أثناء ربط حساب فيسبوك (رمز: ' + res.status + ').');
      showInPageFeedback(genericMsg, true);
      reportResult(false, res.status, 'server_error', { message: genericMsg });
    });
  }).catch(function(err) {
    var netMsg = 'تعذر الاتصال بالسيرفر أثناء حفظ ربط فيسبوك. تحقق من اتصال الإنترنت وحاول مرة أخرى.';
    showInPageFeedback(netMsg, true);
    reportResult(false, 0, 'network_error', { message: netMsg });
  });
})();
''';

      await _webViewController!.runJavaScript(syncJs);

      // 3. Await actual backend response reported by the WebView fetch()
      final Map<String, dynamic> syncResult = await syncCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => {
          'success': false,
          'statusCode': 408,
          'errorType': 'timeout',
          'data': {'message': 'انتهت مهلة مزامنة الربط مع السيرفر.'},
        },
      );

      if (completer.isCompleted) return;

      final Map<String, dynamic> data = syncResult['data'] is Map<String, dynamic>
          ? syncResult['data'] as Map<String, dynamic>
          : <String, dynamic>{};
      final bool ok = syncResult['success'] == true &&
          (data['connected'] == true || data['is_connected'] == true);
      final Map<String, dynamic>? page = data['connected_page'] is Map<String, dynamic>
          ? data['connected_page'] as Map<String, dynamic>
          : null;
      final Map<String, dynamic>? connection = data['connection'] is Map<String, dynamic>
          ? data['connection'] as Map<String, dynamic>
          : null;

      // 4. Dispatch sanitized result to WebView without ever exposing the access token,
      // then perform a single unified reload ONLY after confirmed backend connection.
      if (ok) {
        final String? resolvedPageId =
            page?['id']?.toString() ?? connection?['page_id']?.toString();
        final String? resolvedPageName =
            page?['name']?.toString() ?? connection?['page_name']?.toString();
        final String? resolvedIgUsername =
            connection?['instagram_username']?.toString() ??
            (page?['instagram_account'] is Map
                ? page!['instagram_account']['username']?.toString()
                : null);

        await _dispatchResult({
          'version': 1,
          'requestId': requestId,
          'provider': provider,
          'status': 'success',
          'connected': true,
          if (connection?['id'] != null) 'connectionId': connection!['id'].toString(),
          if (resolvedPageId != null) 'pageId': resolvedPageId,
          if (resolvedPageName != null) 'pageName': resolvedPageName,
          if (resolvedIgUsername != null) 'instagramUsername': resolvedIgUsername,
        });

        await _reloadSocialConnectionsPage();
      } else {
        final int statusCode =
            syncResult['statusCode'] is int ? syncResult['statusCode'] as int : 0;
        final String mappedErrorStatus;
        if (statusCode == 422) {
          mappedErrorStatus = 'permission_denied';
        } else if (statusCode == 401) {
          mappedErrorStatus = 'unauthenticated';
        } else if (statusCode == 419) {
          mappedErrorStatus = 'csrf_mismatch';
        } else {
          mappedErrorStatus = 'backend_error';
        }

        await _dispatchResult({
          'version': 1,
          'requestId': requestId,
          'provider': provider,
          'status': mappedErrorStatus,
          'connected': false,
          'statusCode': statusCode,
          'errorMessage': data['message']?.toString() ?? 'فشل ربط حساب فيسبوك.',
        });
      }
    } catch (e) {
      if (!completer.isCompleted) {
        await _dispatchError(requestId, provider, 'backend_error', 'Internal error: ${e.toString()}');
      }
    } finally {
      timeoutTimer.cancel();
      _pendingWebViewSyncCompleter = null;
      if (!completer.isCompleted) completer.complete();
      _activeRequestId = null;
      _currentAuthCompleter = null;
    }
  }

  /// Performs a single, unified reload of the Social Connections page in the WebView
  /// after backend connection success and bridge event dispatch have completed.
  Future<void> _reloadSocialConnectionsPage() async {
    final WebViewController? controller = _webViewController;
    if (controller == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      final String? currentUrl = await controller.currentUrl();
      if (currentUrl != null && currentUrl.contains('/social-media-and-data')) {
        await controller.reload();
      } else {
        await controller.runJavaScript(
          "window.location.href = '/provider/social-media-and-data';",
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SocialBridgeService] reload error: $e');
      }
    }
  }

  /// Handles `cancel_authorization`
  Future<void> _handleCancelAction(String requestId, String provider) async {
    if (_activeRequestId == requestId && _currentAuthCompleter != null && !_currentAuthCompleter!.isCompleted) {
      _currentAuthCompleter!.complete();
      if (_pendingWebViewSyncCompleter != null && !_pendingWebViewSyncCompleter!.isCompleted) {
        final syncCompleter = _pendingWebViewSyncCompleter!;
        _pendingWebViewSyncCompleter = null;
        syncCompleter.complete({
          'success': false,
          'statusCode': 0,
          'errorType': 'cancelled',
          'data': {'message': 'تم إلغاء العملية.'},
        });
      }
      _activeRequestId = null;
      _currentAuthCompleter = null;

      await _dispatchResult({
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
    await _dispatchResult({
      'version': 1,
      'requestId': requestId,
      'provider': 'facebook',
      'status': 'success',
      'action': 'refresh_status',
    });
  }

  /// Dispatches the final result back to the website via `window.onSocialConnectionResult(...)`
  /// and `PastelSocialConnectionResult` DOM CustomEvent.
  Future<void> _dispatchResult(Map<String, dynamic> payload) async {
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

    try {
      await _webViewController!.runJavaScript(jsCode);
    } catch (err) {
      if (kDebugMode) {
        debugPrint('[SocialBridgeService] runJavaScript error: $err');
      }
    }
  }

  Future<void> _dispatchError(String requestId, String provider, String status, String message) async {
    await _dispatchResult({
      'version': 1,
      'requestId': requestId,
      'provider': provider,
      'status': status,
      'errorMessage': message,
    });
  }
}
