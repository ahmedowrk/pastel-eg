import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/constants.dart';

/// Result status of a native TikTok authorization request.
enum TikTokAuthStatus {
  success,
  cancelled,
  denied,
  failed,
  unsupported,
}

/// Container for the result of a TikTok authorization attempt.
class TikTokAuthResult {
  final TikTokAuthStatus status;
  final String? code;
  final String? codeVerifier;
  final String? state;
  final String? redirectUri;
  final Set<String> grantedScopes;
  final String? errorMessage;

  const TikTokAuthResult({
    required this.status,
    this.code,
    this.codeVerifier,
    this.state,
    this.redirectUri,
    this.grantedScopes = const {},
    this.errorMessage,
  });

  bool get isSuccess => status == TikTokAuthStatus.success && code != null && codeVerifier != null;
}

/// Service managing the Native TikTok OAuth 2.0 Authorization Code flow with PKCE.
///
/// Complies with official TikTok Login Kit v2:
/// - Generates cryptographic PKCE pair (code_verifier and S256 code_challenge)
/// - Generates secure anti-CSRF state token
/// - Requests official approved scopes (e.g. user.info.basic)
/// - Launches official native flow via TikTok App / system browser (NEVER embedded WebView)
/// - Handles callback extraction and state validation
class TikTokAuthService {
  TikTokAuthService._internal();
  static final TikTokAuthService instance = TikTokAuthService._internal();

  Completer<TikTokAuthResult>? _pendingCompleter;
  String? _pendingState;
  String? _pendingCodeVerifier;
  String? _pendingRedirectUri;
  Timer? _authTimeoutTimer;

  /// Generates a high-entropy cryptographic code_verifier conforming to RFC 7636.
  String _generateCodeVerifier() {
    final Random random = Random.secure();
    final List<int> values = List<int>.generate(64, (_) => random.nextInt(256));
    return base64UrlEncode(values).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  }

  /// Calculates the S256 code_challenge from the code_verifier.
  String _generateCodeChallenge(String verifier) {
    final List<int> bytes = ascii.encode(verifier);
    final Digest digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  }

  /// Generates a secure random state string.
  String _generateState() {
    final Random random = Random.secure();
    final List<int> values = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(values).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  }

  /// Initiates the TikTok Login Kit authorization flow.
  ///
  /// Opens the native TikTok application when available, or system browser fallback.
  Future<TikTokAuthResult> authorize({
    List<String> scopes = AppConstants.tiktokDefaultScopes,
    String? clientKey,
    String? redirectUri,
  }) async {
    // Prevent duplicate concurrent authorization requests
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      return const TikTokAuthResult(
        status: TikTokAuthStatus.failed,
        errorMessage: 'هناك عملية تسجيل دخول نشطة حالياً عبر تيك توك.',
      );
    }

    final key = clientKey ?? AppConstants.tiktokClientKey;
    final rUri = redirectUri ?? AppConstants.tiktokWebRedirectUri;

    final String verifier = _generateCodeVerifier();
    final String challenge = _generateCodeChallenge(verifier);
    final String state = _generateState();

    _pendingState = state;
    _pendingCodeVerifier = verifier;
    _pendingRedirectUri = rUri;

    final Completer<TikTokAuthResult> completer = Completer<TikTokAuthResult>();
    _pendingCompleter = completer;

    // Timeout guard: 2 minutes for user interaction
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = Timer(const Duration(minutes: 2), () {
      if (!completer.isCompleted) {
        _cleanup();
        completer.complete(const TikTokAuthResult(
          status: TikTokAuthStatus.cancelled,
          errorMessage: 'انتهت مهلة عملية تسجيل الدخول عبر تيك توك.',
        ));
      }
    });

    final scopesString = scopes.join(',');

    final Uri authUri = Uri.https('www.tiktok.com', '/v2/auth/authorize/', {
      'client_key': key,
      'scope': scopesString,
      'response_type': 'code',
      'redirect_uri': rUri,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    try {
      if (kDebugMode) {
        debugPrint('[TikTokAuthService] Launching TikTok Login: $authUri');
      }

      // Launch with LaunchMode.externalApplication to trigger native TikTok app or system browser
      final bool launched = await launchUrl(
        authUri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        _cleanup();
        return const TikTokAuthResult(
          status: TikTokAuthStatus.unsupported,
          errorMessage: 'تعذر فتح تطبيق تيك توك أو المتصفح الخارجي للمصادقة.',
        );
      }
    } catch (e) {
      _cleanup();
      return TikTokAuthResult(
        status: TikTokAuthStatus.failed,
        errorMessage: 'حدث خطأ أثناء تشغيل تيك توك: $e',
      );
    }

    return completer.future;
  }

  /// Processes the redirect callback URI returned by TikTok.
  ///
  /// Extracts code and state, validates state, and completes the in-flight authorization.
  bool handleCallbackUri(Uri uri) {
    final Map<String, String> params = uri.queryParameters;
    final String? code = params['code'];
    final String? state = params['state'];
    final String? error = params['error'];
    final String? errorDesc = params['error_description'];
    final String? scopesParam = params['scopes'];

    if (_pendingCompleter == null || _pendingCompleter!.isCompleted) {
      if (kDebugMode) {
        debugPrint('[TikTokAuthService] Received callback without pending request.');
      }
      return false;
    }

    // Check for user cancellation or denied permission
    if (error != null) {
      final isCancelled = error == 'user_cancelled' || error == 'access_denied';
      final result = TikTokAuthResult(
        status: isCancelled ? TikTokAuthStatus.cancelled : TikTokAuthStatus.failed,
        errorMessage: errorDesc ?? 'تم إلغاء عملية تسجيل الدخول من تيك توك.',
      );
      _pendingCompleter!.complete(result);
      _cleanup();
      return true;
    }

    // Anti-CSRF verification: state must match
    if (state == null || state != _pendingState) {
      final result = const TikTokAuthResult(
        status: TikTokAuthStatus.failed,
        errorMessage: 'فشل التحقق الأمني: عدم تطابق رمز الحماية (State Mismatch).',
      );
      _pendingCompleter!.complete(result);
      _cleanup();
      return true;
    }

    if (code == null || code.isEmpty) {
      final result = const TikTokAuthResult(
        status: TikTokAuthStatus.failed,
        errorMessage: 'لم يتم استلام رمز المصادقة (Authorization Code) من تيك توك.',
      );
      _pendingCompleter!.complete(result);
      _cleanup();
      return true;
    }

    final Set<String> grantedScopes = scopesParam != null
        ? scopesParam.split(',').map((s) => s.trim()).toSet()
        : <String>{};

    final result = TikTokAuthResult(
      status: TikTokAuthStatus.success,
      code: code,
      codeVerifier: _pendingCodeVerifier,
      state: state,
      redirectUri: _pendingRedirectUri,
      grantedScopes: grantedScopes,
    );

    _pendingCompleter!.complete(result);
    _cleanup();
    return true;
  }

  /// Cancels in-flight authorization request.
  void cancel() {
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
    _pendingCodeVerifier = null;
    _pendingRedirectUri = null;
  }
}
