import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import '../../platform/youtube/youtube_auth_platform.dart';
import '../../utils/constants.dart';
import 'youtube_auth_service.dart';
import 'youtube_channel_service.dart';

enum YouTubeBackendSyncStatus {
  connected,
  rejectedByServer,
  endpointNotFound,
  unauthenticatedSession,
  networkTimeout,
  error,
}

@immutable
class YouTubeBackendSyncResult {
  final YouTubeBackendSyncStatus status;
  final bool isConnected;
  final String? channelId;
  final String? channelTitle;
  final String? accountEmail;
  final int? httpStatus;
  final String? errorCode;
  final String? message;

  const YouTubeBackendSyncResult({
    required this.status,
    required this.isConnected,
    this.channelId,
    this.channelTitle,
    this.accountEmail,
    this.httpStatus,
    this.errorCode,
    this.message,
  });
}

class YouTubeTokenService {
  YouTubeTokenService._internal({
    http.Client? httpClient,
    YouTubeAuthPlatform? authPlatform,
  })  : _httpClient = httpClient,
        _authPlatform = authPlatform;

  static final YouTubeTokenService instance = YouTubeTokenService._internal();

  @visibleForTesting
  factory YouTubeTokenService.forTesting({
    http.Client? httpClient,
    YouTubeAuthPlatform? authPlatform,
  }) {
    return YouTubeTokenService._internal(
      httpClient: httpClient,
      authPlatform: authPlatform,
    );
  }

  final http.Client? _httpClient;
  final YouTubeAuthPlatform? _authPlatform;

  YouTubeAuthPlatform get _platform =>
      _authPlatform ?? YouTubeAuthPlatform.instance;

  static const String kMobileYouTubeConnectTokenPath =
      '/ar/mobile/social/youtube/connect-token';

  static const String kWebYouTubeConnectPath =
      '/provider/automation-settings/provider/social-connections/youtube/connect';
  static const String kWebYouTubeCallbackPath =
      '/provider/automation-settings/provider/social-connections/youtube/callback';

  Completer<Map<String, dynamic>>? _pendingWebViewSyncCompleter;

  Future<YouTubeAuthSession> ensureValidAccessToken({
    required YouTubeAuthSession session,
    String serverClientId = YouTubeAuthService.kPastelYouTubeWebClientId,
    List<String> scopes = YouTubeAuthService.kRequiredYouTubeScopes,
  }) async {
    if (session.isAuthorized && !session.isTokenExpired) {
      return session;
    }

    final email = session.selectedEmail?.trim() ?? '';
    if (email.isEmpty) {
      return const YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.error,
        errorCode: 'missing_email_for_refresh',
        errorMessage: 'لا يمكن تجديد رمز الوصول لعدم وجود بريد Google محدد.',
      );
    }

    final refreshed = await _platform.authorizeYouTubeScopes(
      accountEmail: email,
      serverClientId: serverClientId,
      scopes: scopes,
      forceCodeForRefreshToken: false,
    );

    if (!refreshed.isAuthorized) {
      return YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.error,
        selectedEmail: email,
        errorCode: refreshed.errorCode ?? 'token_refresh_failed',
        errorMessage: refreshed.errorMessage ??
            'انتهت صلاحية جلسة YouTube وتعذر تجديد رمز الوصول تلقائياً. يرجى إعادة ربط الحساب.',
      );
    }

    final expiresAt = refreshed.expiresAtEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(refreshed.expiresAtEpochMs!)
        : DateTime.now().add(const Duration(minutes: 55));

    return YouTubeAuthSession(
      outcome: YouTubeAuthFlowOutcome.authorized,
      selectedEmail: email,
      displayName: session.displayName,
      profilePictureUri: session.profilePictureUri,
      accessToken: refreshed.accessToken,
      serverAuthCode: refreshed.serverAuthCode ?? session.serverAuthCode,
      grantedScopes: refreshed.grantedScopes.isNotEmpty
          ? refreshed.grantedScopes
          : session.grantedScopes,
      expiresAt: expiresAt,
    );
  }

  void handleWebViewChannelMessage(String rawMessage) {
    try {
      final dynamic decoded = jsonDecode(rawMessage);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['action'] == 'youtube_sync_complete') {
        final completer = _pendingWebViewSyncCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete(decoded);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[YouTubeTokenService] Invalid JS message: $e');
      }
    }
  }

  Future<YouTubeBackendSyncResult> syncChannelConnection({
    required YouTubeAuthSession authSession,
    required YouTubeChannelInfo channel,
    WebViewController? webViewController,
    String baseUrl = AppConstants.defaultWebsiteUrl,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final validSession = await ensureValidAccessToken(session: authSession);
    if (!validSession.isAuthorized) {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.error,
        isConnected: false,
        accountEmail: authSession.selectedEmail,
        errorCode: validSession.errorCode ?? 'invalid_session',
        message: validSession.errorMessage ??
            'جلسة تفويض YouTube غير صالحة أو منتهية الصلاحية.',
      );
    }

    final email = validSession.selectedEmail!;
    final accessToken = validSession.accessToken!;
    final expiresInSeconds = validSession.expiresAt != null
        ? validSession.expiresAt!
            .difference(DateTime.now())
            .inSeconds
            .clamp(0, 86400)
        : 3600;

    final payload = <String, dynamic>{
      'provider': 'youtube',
      'google_email': email,
      'access_token': accessToken,
      if (validSession.serverAuthCode != null &&
          validSession.serverAuthCode!.isNotEmpty)
        'server_auth_code': validSession.serverAuthCode,
      'expires_in': expiresInSeconds,
      'granted_scopes': validSession.grantedScopes,
      'channel_id': channel.id,
      'channel_title': channel.title,
      if (channel.customUrl != null) 'channel_custom_url': channel.customUrl,
      if (channel.thumbnailUrl != null)
        'channel_thumbnail': channel.thumbnailUrl,
    };

    if (webViewController != null) {
      return _syncViaWebView(
        webViewController: webViewController,
        payload: payload,
        channel: channel,
        accountEmail: email,
        timeout: timeout,
      );
    }

    return _syncViaHttpClient(
      baseUrl: baseUrl,
      payload: payload,
      channel: channel,
      accountEmail: email,
      timeout: timeout,
    );
  }

  Future<YouTubeBackendSyncResult> _syncViaWebView({
    required WebViewController webViewController,
    required Map<String, dynamic> payload,
    required YouTubeChannelInfo channel,
    required String accountEmail,
    required Duration timeout,
  }) async {
    if (_pendingWebViewSyncCompleter != null &&
        !_pendingWebViewSyncCompleter!.isCompleted) {
      _pendingWebViewSyncCompleter!.completeError(
        StateError('Superseded by a newer YouTube sync request'),
      );
    }

    final completer = Completer<Map<String, dynamic>>();
    _pendingWebViewSyncCompleter = completer;

    final jsPayload = jsonEncode(payload);
    final jsEndpoint = jsonEncode(kMobileYouTubeConnectTokenPath);

    final jsCode = '''
(function() {
  function reportYouTubeSync(resultObj) {
    try {
      if (window.PastelYouTubeChannel && typeof window.PastelYouTubeChannel.postMessage === 'function') {
        window.PastelYouTubeChannel.postMessage(JSON.stringify(resultObj));
      }
    } catch (_) {}
  }

  try {
    var csrfMeta = document.querySelector('meta[name="csrf-token"]');
    var csrfToken = csrfMeta ? (csrfMeta.getAttribute('content') || '') : '';
    if (!csrfToken) {
      var cookies = document.cookie.split(';');
      for (var i = 0; i < cookies.length; i++) {
        var c = cookies[i].trim();
        if (c.indexOf('XSRF-TOKEN=') === 0) {
          csrfToken = decodeURIComponent(c.substring(11));
          break;
        }
      }
    }

    var bodyPayload = $jsPayload;
    if (csrfToken) {
      bodyPayload._token = csrfToken;
    }

    fetch($jsEndpoint, {
      method: 'POST',
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-TOKEN': csrfToken
      },
      body: JSON.stringify(bodyPayload)
    })
    .then(function(res) {
      return res.text().then(function(rawText) {
        var data = {};
        try {
          data = rawText ? JSON.parse(rawText) : {};
        } catch (_) {}

        var isConfirmedConnected = res.ok && (
          data.connected === true ||
          data.is_connected === true
        );

        reportYouTubeSync({
          action: 'youtube_sync_complete',
          ok: isConfirmedConnected,
          httpStatus: res.status,
          connected: isConfirmedConnected,
          errorCode: data.error_code || (res.status === 404 ? 'endpoint_not_found' : null),
          message: data.message || data.error || ''
        });
      });
    })
    .catch(function(err) {
      reportYouTubeSync({
        action: 'youtube_sync_complete',
        ok: false,
        httpStatus: 0,
        connected: false,
        errorCode: 'fetch_network_error',
        message: err ? String(err) : 'Network error during YouTube token sync'
      });
    });
  } catch (e) {
    reportYouTubeSync({
      action: 'youtube_sync_complete',
      ok: false,
      httpStatus: 0,
      connected: false,
      errorCode: 'js_execution_error',
      message: e ? String(e) : 'Unexpected JS error'
    });
  }
})();
''';

    try {
      await webViewController.runJavaScript(jsCode);
      final responseMap = await completer.future.timeout(timeout);
      return _parseSyncResponseMap(
        responseMap: responseMap,
        channel: channel,
        accountEmail: accountEmail,
      );
    } on TimeoutException {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.networkTimeout,
        isConnected: false,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        errorCode: 'sync_timeout',
        message:
            'انتهت مهلة مزامنة بيانات قناة YouTube مع خادم Pastel. يرجى المحاولة مرة أخرى.',
      );
    } catch (e) {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.error,
        isConnected: false,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        errorCode: 'webview_sync_failed',
        message: 'تعذر إرسال بيانات ربط قناة YouTube إلى الخادم.',
      );
    } finally {
      if (identical(_pendingWebViewSyncCompleter, completer)) {
        _pendingWebViewSyncCompleter = null;
      }
    }
  }

  Future<YouTubeBackendSyncResult> _syncViaHttpClient({
    required String baseUrl,
    required Map<String, dynamic> payload,
    required YouTubeChannelInfo channel,
    required String accountEmail,
    required Duration timeout,
  }) async {
    final client = _httpClient ?? http.Client();
    final shouldClose = _httpClient == null;

    try {
      final normalizedBase = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final uri = Uri.parse('$normalizedBase$kMobileYouTubeConnectTokenPath');

      final response = await client
          .post(
            uri,
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'X-Requested-With': 'XMLHttpRequest',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      Map<String, dynamic> data = const <String, dynamic>{};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      } catch (_) {}

      final isConfirmedConnected = response.statusCode >= 200 &&
          response.statusCode < 300 &&
          (data['connected'] == true || data['is_connected'] == true);

      return _parseSyncResponseMap(
        responseMap: <String, dynamic>{
          'ok': isConfirmedConnected,
          'httpStatus': response.statusCode,
          'connected': isConfirmedConnected,
          'errorCode': data['error_code'] ??
              (response.statusCode == 404 ? 'endpoint_not_found' : null),
          'message': data['message'] ?? data['error'] ?? '',
        },
        channel: channel,
        accountEmail: accountEmail,
      );
    } on TimeoutException {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.networkTimeout,
        isConnected: false,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        errorCode: 'http_timeout',
        message: 'انتهت مهلة الاتصال بخادم Pastel أثناء حفظ ربط قناة YouTube.',
      );
    } catch (e) {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.error,
        isConnected: false,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        errorCode: 'http_sync_error',
        message: 'حدث خطأ أثناء الاتصال بخادم Pastel لحفظ ربط قناة YouTube.',
      );
    } finally {
      if (shouldClose) {
        client.close();
      }
    }
  }

  YouTubeBackendSyncResult _parseSyncResponseMap({
    required Map<String, dynamic> responseMap,
    required YouTubeChannelInfo channel,
    required String accountEmail,
  }) {
    final int httpStatus = (responseMap['httpStatus'] as num?)?.toInt() ?? 0;
    final bool isConnected =
        responseMap['ok'] == true && responseMap['connected'] == true;
    final String rawMessage =
        (responseMap['message'] as String? ?? '').trim();
    final String? errorCode = responseMap['errorCode'] as String?;

    if (isConnected) {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.connected,
        isConnected: true,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        httpStatus: httpStatus,
        message: rawMessage.isNotEmpty
            ? rawMessage
            : 'تم ربط قناة YouTube (${channel.title}) بنجاح.',
      );
    }

    if (httpStatus == 404 || errorCode == 'endpoint_not_found') {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.endpointNotFound,
        isConnected: false,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        httpStatus: 404,
        errorCode: 'endpoint_not_found',
        message:
            'تم التحقق من قناة YouTube (${channel.title}) للحساب ($accountEmail) بنجاح، '
            'ولكن مسار الحفظ على الخادم ($kMobileYouTubeConnectTokenPath) غير مفعّل بعد على الباك إند.',
      );
    }

    if (httpStatus == 401 || httpStatus == 419) {
      return YouTubeBackendSyncResult(
        status: YouTubeBackendSyncStatus.unauthenticatedSession,
        isConnected: false,
        channelId: channel.id,
        channelTitle: channel.title,
        accountEmail: accountEmail,
        httpStatus: httpStatus,
        errorCode: 'unauthenticated_session',
        message: rawMessage.isNotEmpty
            ? rawMessage
            : 'انتهت جلسة تسجيل الدخول في Pastel. يرجى تحديث الصفحة وتسجيل الدخول ثم المحاولة مرة أخرى.',
      );
    }

    return YouTubeBackendSyncResult(
      status: YouTubeBackendSyncStatus.rejectedByServer,
      isConnected: false,
      channelId: channel.id,
      channelTitle: channel.title,
      accountEmail: accountEmail,
      httpStatus: httpStatus,
      errorCode: errorCode ?? 'server_rejected',
      message: rawMessage.isNotEmpty
          ? rawMessage
          : 'تعذر تأكيد ربط قناة YouTube من الخادم (HTTP $httpStatus).',
    );
  }
}
