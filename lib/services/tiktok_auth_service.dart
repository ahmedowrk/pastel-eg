import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../utils/constants.dart';

/// Result status of a native TikTok OpenSDK authorization request.
enum TikTokAuthStatus {
  success,
  cancelled,
  denied,
  failed,
  unsupported,
}

/// Container for the result of a TikTok OpenSDK authorization attempt.
class TikTokAuthResult {
  final TikTokAuthStatus status;
  final String? code;
  final String? codeVerifier;
  final String? state;
  final String? redirectUri;
  final Set<String> grantedScopes;
  final bool usedNativeApp;
  final String? errorMessage;

  const TikTokAuthResult({
    required this.status,
    this.code,
    this.codeVerifier,
    this.state,
    this.redirectUri,
    this.grantedScopes = const {},
    this.usedNativeApp = false,
    this.errorMessage,
  });

  bool get isSuccess =>
      status == TikTokAuthStatus.success &&
      code != null &&
      code!.isNotEmpty &&
      codeVerifier != null &&
      codeVerifier!.isNotEmpty;
}

/// Service bridging Flutter to the official native TikTok OpenSDK v2:
/// - Android: `com.tiktok.open.sdk:tiktok-open-sdk-auth:2.4.0` (`AuthApi`, `AuthRequest`, `PKCEUtils`)
///   using `AuthApi.AuthMethod.TikTokApp` (which verifies and launches the installed TikTok app via
///   `TikTokAppCheckUtil` and falls back to `AuthApi.AuthMethod.ChromeTab` via `CustomTabsIntent`).
/// - iOS: `TikTokOpenAuthSDK` (`~> 2.5.0`) (`TikTokAuthRequest`, `TTKSDKCodeVerifier`, `TikTokURLHandler`)
///   using Universal Links (`https://pastel-eg.com/social-connections/tiktok/callback`) and
///   `ASWebAuthenticationSession` fallback.
class TikTokAuthService {
  TikTokAuthService._internal() {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  static final TikTokAuthService instance = TikTokAuthService._internal();

  static const MethodChannel _channel = MethodChannel('com.pasteleg.app/tiktok_sdk');

  Completer<TikTokAuthResult>? _pendingCompleter;
  String? _pendingState;
  String? _pendingRedirectUri;
  Timer? _authTimeoutTimer;

  /// Generates a high-entropy cryptographic anti-CSRF state string.
  String _generateState() {
    final Random random = Random.secure();
    final List<int> values = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(values)
        .replaceAll('=', '')
        .replaceAll('+', '-')
        .replaceAll('/', '_');
  }

  /// Queries the native TikTok OpenSDK to determine if the official TikTok app
  /// is installed and signature-verified on the user's device.
  Future<bool> isTikTokAppInstalled() async {
    try {
      final bool? installed = await _channel.invokeMethod<bool>('isTikTokInstalled');
      return installed ?? false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TikTokAuthService] isTikTokAppInstalled error: $e');
      }
      return false;
    }
  }

  /// Initiates the official TikTok OpenSDK Login Kit v2 authorization flow.
  ///
  /// - Prioritizes the installed TikTok native app (`AuthMethod.TikTokApp` on Android,
  ///   Universal Link handoff on iOS).
  /// - Falls back to `AuthMethod.ChromeTab` (Android) or `ASWebAuthenticationSession` (iOS)
  ///   when the TikTok app is not installed.
  /// - PKCE (`code_verifier` and hex-encoded SHA-256 `code_challenge`) is generated
  ///   directly by the native TikTok OpenSDK (`PKCEUtils` on Android, `TTKSDKCodeVerifier` on iOS).
  Future<TikTokAuthResult> authorize({
    List<String> scopes = AppConstants.tiktokDefaultScopes,
    String? clientKey,
    String? redirectUri,
    bool preferNative = true,
  }) async {
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      return const TikTokAuthResult(
        status: TikTokAuthStatus.failed,
        errorMessage: 'هناك عملية تسجيل دخول نشطة حالياً عبر تيك توك.',
      );
    }

    final String key = clientKey ?? AppConstants.tiktokClientKey;
    final String rUri = redirectUri ?? AppConstants.tiktokRedirectUri;
    final String state = _generateState();
    final String scopesString = scopes.join(',');

    _pendingState = state;
    _pendingRedirectUri = rUri;

    final Completer<TikTokAuthResult> completer = Completer<TikTokAuthResult>();
    _pendingCompleter = completer;

    // 2-minute timeout guard in case user abandons the external TikTok app or Chrome Custom Tab
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = Timer(const Duration(minutes: 2), () {
      if (!completer.isCompleted) {
        _channel.invokeMethod('cancel').catchError((_) {});
        _cleanup();
        completer.complete(const TikTokAuthResult(
          status: TikTokAuthStatus.cancelled,
          errorMessage: 'انتهت مهلة عملية تسجيل الدخول عبر تيك توك.',
        ));
      }
    });

    try {
      if (kDebugMode) {
        debugPrint(
          '[TikTokAuthService] Invoking Native TikTok OpenSDK (preferNative: $preferNative, redirectUri: $rUri)',
        );
      }

      final dynamic rawResponse = await _channel.invokeMethod<dynamic>('authorize', {
        'clientKey': key,
        'scope': scopesString,
        'redirectUri': rUri,
        'state': state,
        'preferNative': preferNative,
        'language': 'ar',
      });

      if (!completer.isCompleted && rawResponse is Map) {
        final TikTokAuthResult parsed = _parseNativeResponse(
          Map<String, dynamic>.from(rawResponse),
        );
        _cleanup();
        completer.complete(parsed);
      }
    } on PlatformException catch (e) {
      if (!completer.isCompleted) {
        _cleanup();
        completer.complete(TikTokAuthResult(
          status: TikTokAuthStatus.failed,
          errorMessage: e.message ?? 'تعذر تشغيل مصادقة تيك توك الأصلية (${e.code}).',
        ));
      }
    } catch (e) {
      if (!completer.isCompleted) {
        _cleanup();
        completer.complete(TikTokAuthResult(
          status: TikTokAuthStatus.failed,
          errorMessage: 'حدث خطأ أثناء تشغيل تيك توك: $e',
        ));
      }
    }

    return completer.future;
  }

  /// Handles asynchronous `onAuthResponse` events dispatched from `MainActivity.onNewIntent`
  /// if the activity was recreated while backgrounded.
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onAuthResponse' && call.arguments is Map) {
      if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
        final TikTokAuthResult parsed = _parseNativeResponse(
          Map<String, dynamic>.from(call.arguments as Map),
        );
        final Completer<TikTokAuthResult> active = _pendingCompleter!;
        _cleanup();
        active.complete(parsed);
      }
    }
    return null;
  }

  TikTokAuthResult _parseNativeResponse(Map<String, dynamic> map) {
    final String statusStr = (map['status']?.toString() ?? 'failed').toLowerCase();
    final String? code = map['code']?.toString();
    final String? codeVerifier = map['codeVerifier']?.toString();
    final String? responseState = map['state']?.toString();
    final String? redirectUri = map['redirectUri']?.toString() ?? _pendingRedirectUri;
    final String? grantedStr = map['grantedPermissions']?.toString();
    final bool usedNativeApp = map['usedNativeApp'] == true;
    final String? errorMessage = map['errorMessage']?.toString();

    if (statusStr == 'success') {
      // Anti-CSRF state check (defense-in-depth on top of native verification)
      if (_pendingState != null &&
          _pendingState!.isNotEmpty &&
          responseState != _pendingState) {
        return TikTokAuthResult(
          status: TikTokAuthStatus.failed,
          usedNativeApp: usedNativeApp,
          errorMessage: 'فشل التحقق الأمني: عدم تطابق رمز الحماية (State Mismatch).',
        );
      }

      if (code == null || code.isEmpty || codeVerifier == null || codeVerifier.isEmpty) {
        return TikTokAuthResult(
          status: TikTokAuthStatus.failed,
          usedNativeApp: usedNativeApp,
          errorMessage: 'لم يتم استلام رمز التفويض أو مفتاح التحقق PKCE من TikTok OpenSDK.',
        );
      }

      final Set<String> grantedScopes = (grantedStr != null && grantedStr.isNotEmpty)
          ? grantedStr
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet()
          : AppConstants.tiktokDefaultScopes.toSet();

      return TikTokAuthResult(
        status: TikTokAuthStatus.success,
        code: code,
        codeVerifier: codeVerifier,
        state: responseState ?? _pendingState,
        redirectUri: redirectUri,
        grantedScopes: grantedScopes,
        usedNativeApp: usedNativeApp,
      );
    }

    final TikTokAuthStatus mappedStatus;
    switch (statusStr) {
      case 'cancelled':
        mappedStatus = TikTokAuthStatus.cancelled;
        break;
      case 'denied':
        mappedStatus = TikTokAuthStatus.denied;
        break;
      case 'unsupported':
        mappedStatus = TikTokAuthStatus.unsupported;
        break;
      default:
        mappedStatus = TikTokAuthStatus.failed;
    }

    return TikTokAuthResult(
      status: mappedStatus,
      usedNativeApp: usedNativeApp,
      errorMessage: errorMessage ?? 'تم إلغاء أو رفض عملية تسجيل الدخول من تيك توك.',
    );
  }

  /// Defensive fallback if the WebView ever intercepts the HTTPS callback URI directly.
  bool handleCallbackUri(Uri uri) {
    if (_pendingCompleter == null || _pendingCompleter!.isCompleted) {
      return false;
    }
    final Map<String, String> params = uri.queryParameters;
    final String? error = params['error'];
    final String? errorDesc = params['error_description'];
    if (error != null) {
      final bool isCancelled = error == 'user_cancelled' || error == 'access_denied';
      final Completer<TikTokAuthResult> active = _pendingCompleter!;
      _cleanup();
      active.complete(TikTokAuthResult(
        status: isCancelled ? TikTokAuthStatus.cancelled : TikTokAuthStatus.failed,
        errorMessage: errorDesc ?? 'تم إلغاء عملية تسجيل الدخول من تيك توك.',
      ));
      return true;
    }
    return false;
  }

  /// Cancels any in-flight authorization request.
  void cancel() {
    _channel.invokeMethod('cancel').catchError((_) {});
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete(const TikTokAuthResult(
        status: TikTokAuthStatus.cancelled,
        errorMessage: 'تم إلغاء العملية بواسطة المستخدم.',
      ));
    }
    _cleanup();
  }

  void _cleanup() {
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = null;
    _pendingCompleter = null;
    _pendingState = null;
    _pendingRedirectUri = null;
  }
}
