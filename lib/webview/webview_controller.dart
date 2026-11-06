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
import '../services/social_bridge_service.dart';
import '../utils/constants.dart';

/// iOS Mobile Safari User-Agent (without "Android" or "wv").
///
/// Fixes:
/// 1) "Something went wrong — Use your passkey again" on Android WebView when
///    logging in with Facebook / Instagram.
/// 2) Preserves `laravel_session` and Facebook `datr` cookies inside the same
///    WebView so `/meta/connect` -> `m.facebook.com` -> `/meta/callback`
///    completes and links the Facebook Page / Instagram account cleanly.
const String _kPasskeyFreeSafariUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/16.6 Mobile/15E148 Safari/604.1';

/// JavaScript shim injected on every page load to disable WebAuthn / Passkey
/// prompts (`PublicKeyCredential` & `autocomplete="username webauthn"`) so
/// Facebook and Instagram never trigger the broken Passkey modal in WebView.
const String _kDisablePasskeyJs = '''
(function() {
  try {
    if (window.PublicKeyCredential) {
      window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
        return Promise.resolve(false);
      };
      window.PublicKeyCredential.isConditionalMediationAvailable = function() {
        return Promise.resolve(false);
      };
      delete window.PublicKeyCredential;
    }
    if (navigator.credentials) {
      navigator.credentials.get = function() {
        return Promise.reject(new DOMException('Passkeys disabled in WebView', 'NotSupportedError'));
      };
      navigator.credentials.create = function() {
        return Promise.reject(new DOMException('Passkeys disabled in WebView', 'NotSupportedError'));
      };
    }
    function stripWebAuthnAutocomplete() {
      var inputs = document.querySelectorAll('input[autocomplete*="webauthn"]');
      for (var i = 0; i < inputs.length; i++) {
        inputs[i].setAttribute('autocomplete', 'username');
      }
    }
    stripWebAuthnAutocomplete();
    var observer = new MutationObserver(stripWebAuthnAutocomplete);
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
  } catch (e) {}
})();
''';

class AppWebViewController with WidgetsBindingObserver {
  final ValueChanged<int>? onProgressChanged;
  final VoidCallback? onPageStarted;
  final VoidCallback? onPageFinished;
  final void Function(WebResourceError error)? onWebResourceError;

  late final WebViewController controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  final ImagePicker _imagePicker = ImagePicker();

  String? _lastRegisteredToken;
  bool _isSyncingToken = false;

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
      ..setUserAgent(_kPasskeyFreeSafariUserAgent)
      ..addJavaScriptChannel(
        'FlutterFCMChannel',
        onMessageReceived: _handleFcmChannelMessage,
      )
      ..addJavaScriptChannel(
        'NotificationStateChannel',
        onMessageReceived: (JavaScriptMessage message) {
          NotificationStateService.instance.handleJavascriptMessage(
            message.message,
          );
        },
      )
      ..addJavaScriptChannel(
        'PastelNativeChannel',
        onMessageReceived: (JavaScriptMessage message) {
          controller.currentUrl().then((url) {
            SocialBridgeService.instance.handleJavascriptMessage(
              message.message,
              url,
            );
          });
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => onProgressChanged?.call(progress),
          onPageStarted: (_) {
            onPageStarted?.call();
            controller.runJavaScript(_kDisablePasskeyJs);
            controller.runJavaScript(SocialBridgeService.kPastelNativeInjectionJs);
          },
          onPageFinished: (url) {
            onPageFinished?.call();
            controller.runJavaScript(_kDisablePasskeyJs);
            controller.runJavaScript(SocialBridgeService.kPastelNativeInjectionJs);
            _attemptFcmTokenSync(url);
            NotificationStateService.instance.syncState();
          },
          onWebResourceError: (error) => onWebResourceError?.call(error),
          onNavigationRequest: _handleNavigationRequest,
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));

    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setOnShowFileSelector(_onShowFileSelector);
      AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(platformController, true);
    }

    SocialBridgeService.instance.attachController(controller);
    NotificationService.instance.tokenNotifier.addListener(_onFcmTokenChanged);
    NotificationStateService.instance.attachWebViewController(controller);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Clears ONLY Facebook's active user session cookies (`c_user`, `xs`, `fr`)
  /// while keeping Pastel's `laravel_session` and Facebook's device `datr`
  /// cookie intact. This allows logging into a different Facebook account cleanly.
  Future<void> clearFacebookSessionCookies() async {
    const fbSessionCookies = ['c_user', 'xs', 'fr'];
    const fbDomains = ['.facebook.com', 'm.facebook.com', 'www.facebook.com'];

    for (final domain in fbDomains) {
      for (final name in fbSessionCookies) {
        try {
          await _cookieManager.setCookie(
            WebViewCookie(
              name: name,
              value: '',
              domain: domain,
              path: '/',
            ),
          );
        } catch (_) {}
      }
    }
  }

  void _onFcmTokenChanged() {
    controller.currentUrl().then((url) {
      if (url != null) {
        _attemptFcmTokenSync(url.toString());
      }
    });
  }

  Future<void> _attemptFcmTokenSync(String currentUrl) async {
    final token = NotificationService.instance.currentToken;
    if (token == null || token.isEmpty) return;

    final uri = Uri.tryParse(currentUrl);
    if (uri == null || !uri.host.contains('pastel-eg.com')) return;

    if (_lastRegisteredToken == token || _isSyncingToken) return;
    _isSyncingToken = true;

    try {
      final deviceName = await DeviceInfoService.instance.getDeviceName();
      final platform = Platform.isAndroid ? 'android' : 'ios';

      final jsCode =
          '''
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
    }
  })
  .catch(function() {});
})();
''';

      await controller.runJavaScript(jsCode);
    } catch (e) {
      if (kDebugMode)
        debugPrint('[AppWebViewController] FCM JS sync error: $e');
    } finally {
      _isSyncingToken = false;
    }
  }

  Future<List<String>> _onShowFileSelector(FileSelectorParams params) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
      );
      if (image == null) return [];
      return [Uri.file(image.path).toString()];
    } catch (e) {
      return [];
    }
  }

  void _handleFcmChannelMessage(JavaScriptMessage message) {
    try {
      final Map<String, dynamic> data = jsonDecode(message.message);
      if (data['status'] == 'success') {
        _lastRegisteredToken = NotificationService.instance.currentToken;
      }
    } catch (_) {}
  }

  void loadUrl(String url) {
    controller.loadRequest(Uri.parse(url));
  }

  Future<bool> canGoBack() => controller.canGoBack();
  Future<void> goBack() => controller.goBack();
  Future<void> reload() => controller.reload();

  Future<NavigationDecision> _handleNavigationRequest(
    NavigationRequest request,
  ) async {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.navigate;

    // Intercept Facebook OAuth navigation: NEVER open inside embedded WebView!
    final bool isFacebookOAuth = (uri.host.contains('facebook.com') &&
        (uri.path.contains('/dialog/oauth') || uri.path.contains('/login')));
    final bool isPastelMetaConnect = (uri.host.contains('pastel-eg.com') &&
        uri.path.contains('/social-connections/meta/connect'));

    if (isFacebookOAuth || isPastelMetaConnect) {
      // Trigger Native Facebook Login flow directly
      SocialBridgeService.instance.startDirectFacebookLogin(provider: 'facebook');
      return NavigationDecision.prevent;
    }

    final isSpecialScheme = !uri.scheme.startsWith('http');
    if (isSpecialScheme) {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return NavigationDecision.prevent;
    }

    return NavigationDecision.navigate;
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.instance.tokenNotifier.removeListener(
      _onFcmTokenChanged,
    );
  }
}
