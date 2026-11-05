import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../firebase/notification_service.dart';
import '../services/device_info_service.dart';
import '../services/notification_state_service.dart';
import '../utils/constants.dart';

/// Chrome-like User-Agent string that removes the "wv" (WebView) marker.
/// Facebook and other OAuth providers detect "wv" in the UA and block or
/// restrict OAuth flows / force Passkeys which Android WebView cannot handle.
const String _kChromeUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Mobile Safari/537.36';

/// Builds and configures a [WebViewController] with full WebView capabilities
/// including an automated, authenticated FCM token registration bridge for
/// the Provider session on Laravel (`/ar/fcm/device-token`).
///
/// OAuth-aware: overrides the default WebView User-Agent so that Facebook and
/// similar providers treat the WebView as a first-class browser (not an
/// embedded "wv" WebView). This avoids Passkey/FIDO2 prompts and the
/// resulting "Something went wrong" errors.
class AppWebViewController with WidgetsBindingObserver {
  final ValueChanged<int>? onProgressChanged;
  final VoidCallback? onPageStarted;
  final VoidCallback? onPageFinished;
  final void Function(WebResourceError error)? onWebResourceError;

  late final WebViewController controller;

  final ImagePicker _imagePicker = ImagePicker();

  /// Tracks the last token successfully registered to avoid redundant requests.
  String? _lastRegisteredToken;
  bool _isSyncingToken = false;

  /// Set to `true` when we open an external browser for OAuth so that we
  /// know to reload the WebView when the user comes back to the app.
  bool _waitingForExternalAuth = false;

  AppWebViewController({
    required String initialUrl,
    this.onProgressChanged,
    this.onPageStarted,
    this.onPageFinished,
    this.onWebResourceError,
  }) {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setUserAgent(_kChromeUserAgent)
      ..addJavaScriptChannel(
        'FlutterFCMChannel',
        onMessageReceived: _handleFcmChannelMessage,
      )
      ..addJavaScriptChannel(
        'NotificationStateChannel',
        onMessageReceived: (JavaScriptMessage message) {
          NotificationStateService.instance
              .handleJavascriptMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => onProgressChanged?.call(progress),
          onPageStarted: (_) => onPageStarted?.call(),
          onPageFinished: (url) {
            onPageFinished?.call();
            _attemptFcmTokenSync(url);
            NotificationStateService.instance.syncState();
          },
          onWebResourceError: (error) => onWebResourceError?.call(error),
          onNavigationRequest: _handleNavigationRequest,
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));

    // ── Android-specific WebView settings ──
    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setOnShowFileSelector(_onShowFileSelector);
    }

    // Listen for FCM token changes (e.g. initial fetch or rotation)
    NotificationService.instance.tokenNotifier.addListener(_onFcmTokenChanged);

    NotificationStateService.instance.attachWebViewController(controller);

    // Observe app lifecycle to reload WebView when returning from external auth.
    WidgetsBinding.instance.addObserver(this);
  }

  // ── Lifecycle observer ──────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForExternalAuth) {
      _waitingForExternalAuth = false;
      // Reload so the WebView picks up the session/link state that was
      // established in the external browser.
      if (kDebugMode) {
        debugPrint('[AppWebViewController] Returned from external auth – reloading WebView');
      }
      controller.reload();
    }
  }

  // ── FCM token sync ──────────────────────────────────────────────────────

  void _onFcmTokenChanged() {
    controller.currentUrl().then((url) {
      if (url != null) {
        _attemptFcmTokenSync(url.toString());
      }
    });
  }

  /// Attempts to register the FCM token into the active Laravel Provider session.
  ///
  /// Runs inside the WebView DOM context using native `fetch()`, which automatically
  /// includes the authenticated WebView session cookies (`laravel_session`, etc.) and
  /// extracts the CSRF token (`meta[name="csrf-token"]` or `XSRF-TOKEN` cookie).
  Future<void> _attemptFcmTokenSync(String currentUrl) async {
    final token = NotificationService.instance.currentToken;
    if (token == null || token.isEmpty) return;

    // Only attempt sync on the main site domain
    final uri = Uri.tryParse(currentUrl);
    if (uri == null || !uri.host.contains('pastel-eg.com')) return;

    if (_lastRegisteredToken == token || _isSyncingToken) return;
    _isSyncingToken = true;

    try {
      final deviceName = await DeviceInfoService.instance.getDeviceName();
      final platform = Platform.isAndroid ? 'android' : 'ios';

      final jsCode = '''
(function() {
  var fcmToken = ${jsonEncode(token)};
  var platform = ${jsonEncode(platform)};
  var deviceName = ${jsonEncode(deviceName)};

  function getCsrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    if (meta && meta.getAttribute('content')) {
      return meta.getAttribute('content');
    }
    var cookies = document.cookie.split(';');
    for (var i = 0; i < cookies.length; i++) {
      var c = cookies[i].trim();
      if (c.indexOf('XSRF-TOKEN=') === 0) {
        return decodeURIComponent(c.substring(11));
      }
    }
    return '';
  }

  var csrfToken = getCsrfToken();

  fetch(${jsonEncode(AppConstants.deviceTokenPath)}, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-CSRF-TOKEN': csrfToken,
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: JSON.stringify({
      token: fcmToken,
      platform: platform,
      device_name: deviceName
    }),
    credentials: 'include'
  })
  .then(function(res) {
    if (res.ok) {
      return res.json().then(function(data) {
        if (window.FlutterFCMChannel) {
          window.FlutterFCMChannel.postMessage(JSON.stringify({ status: 'success', data: data }));
        }
      });
    } else {
      if (window.FlutterFCMChannel) {
        window.FlutterFCMChannel.postMessage(JSON.stringify({ status: 'unauthorized_or_error', httpCode: res.status }));
      }
    }
  })
  .catch(function(err) {
    if (window.FlutterFCMChannel) {
      window.FlutterFCMChannel.postMessage(JSON.stringify({ status: 'network_error', error: err.toString() }));
    }
  });
})();
''';

      await controller.runJavaScript(jsCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[AppWebViewController] FCM JS sync error: $e');
    } finally {
      _isSyncingToken = false;
    }
  }

  // ── File picker ─────────────────────────────────────────────────────────

  Future<List<String>> _onShowFileSelector(FileSelectorParams params) async {
    try {
      final XFile? image =
          await _imagePicker.pickImage(source: ImageSource.gallery);
      if (image == null) return [];
      return [Uri.file(image.path).toString()];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppWebViewController] Image picker error: $e');
      }
      return [];
    }
  }

  // ── FCM channel handler ─────────────────────────────────────────────────

  void _handleFcmChannelMessage(JavaScriptMessage message) {
    try {
      final Map<String, dynamic> data = jsonDecode(message.message);
      final status = data['status'];
      if (status == 'success') {
        _lastRegisteredToken = NotificationService.instance.currentToken;
        if (kDebugMode) {
          debugPrint(
              '[AppWebViewController] FCM token registered successfully in Laravel session: ${data['data']}');
        }
      } else {
        if (kDebugMode) {
          debugPrint(
              '[AppWebViewController] FCM token registration response: $data');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            '[AppWebViewController] Error parsing JS channel message: $e');
      }
    }
  }

  // ── Public helpers ──────────────────────────────────────────────────────

  /// Loads a new URL, e.g. when a notification is tapped.
  void loadUrl(String url) {
    controller.loadRequest(Uri.parse(url));
  }

  Future<bool> canGoBack() => controller.canGoBack();

  Future<void> goBack() => controller.goBack();

  Future<void> reload() => controller.reload();

  // ── Navigation policy ───────────────────────────────────────────────────

  Future<NavigationDecision> _handleNavigationRequest(
    NavigationRequest request,
  ) async {
    final uri = Uri.tryParse(request.url);

    if (uri == null) {
      return NavigationDecision.navigate;
    }

    final isSpecialScheme = !uri.scheme.startsWith('http');

    // Facebook / Meta OAuth URLs must open in Chrome Custom Tabs —
    // a real Chrome browser that supports Passkeys and all JS APIs.
    // The WebView (even with Chrome UA) lacks WebAuthn and other APIs
    // that Facebook's login flow requires.
    if (_isFacebookUrl(uri)) {
      if (kDebugMode) {
        debugPrint('[AppWebViewController] Opening Facebook in Custom Tab: ${request.url}');
      }
      _waitingForExternalAuth = true;
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
      if (launched) return NavigationDecision.prevent;
    }

    if (isSpecialScheme) {
      if (kDebugMode) {
        debugPrint('[AppWebViewController] Opening externally: ${request.url}');
      }
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return NavigationDecision.prevent;
    }

    return NavigationDecision.navigate;
  }

  /// Whether [uri] belongs to the Facebook / Meta OAuth domain family.
  bool _isFacebookUrl(Uri uri) {
    const facebookHosts = {
      'facebook.com',
      'www.facebook.com',
      'm.facebook.com',
      'web.facebook.com',
      'z-m.facebook.com',
    };
    final host = uri.host.toLowerCase();
    return facebookHosts.any((fb) => host == fb || host.endsWith('.$fb'));
  }

  // ── Cleanup ─────────────────────────────────────────────────────────────

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.instance.tokenNotifier.removeListener(_onFcmTokenChanged);
  }
}
