import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

/// Represents the validated response returned by the Pastel Laravel backend after
/// verifying and exchanging a native TikTok authorization code + PKCE verifier.
class TikTokBackendConnectResult {
  final bool isSuccess;
  final String status; // 'success' | 'permission_denied' | 'authentication_failed' | 'account_already_linked' | 'backend_error'
  final String? connectionId;
  final String? openId;
  final String? displayName;
  final String? avatarUrl;
  final String? errorCode;
  final String? errorMessage;

  const TikTokBackendConnectResult({
    required this.isSuccess,
    required this.status,
    this.connectionId,
    this.openId,
    this.displayName,
    this.avatarUrl,
    this.errorCode,
    this.errorMessage,
  });

  /// Formats the result into the standard Pastel social bridge payload schema,
  /// matching `BackendSocialConnectResult.toBridgePayload` in `social_backend_service.dart`.
  Map<String, dynamic> toBridgePayload(String requestId) {
    if (isSuccess) {
      return {
        'version': 1,
        'requestId': requestId,
        'provider': 'tiktok',
        'status': 'success',
        'connectionId': connectionId,
        'pageId': openId,
        'pageName': displayName,
        'connectedAccount': {
          'openId': openId,
          'displayName': displayName,
          if (avatarUrl != null && avatarUrl!.isNotEmpty) 'avatarUrl': avatarUrl,
        },
        'message': 'تم ربط حساب تيك توك بنجاح',
      };
    } else {
      return {
        'version': 1,
        'requestId': requestId,
        'provider': 'tiktok',
        'status': status,
        if (errorCode != null && errorCode!.isNotEmpty) 'errorCode': errorCode,
        'errorMessage': errorMessage ?? 'فشل التحقق من ربط حساب تيك توك مع الخادم.',
      };
    }
  }
}

/// Service responsible for securely sending the single-use TikTok authorization code
/// and PKCE code_verifier to the canonical Pastel Laravel endpoint.
///
/// Security invariants:
/// - The mobile client NEVER holds the TikTok Client Secret.
/// - The mobile client NEVER exchanges the authorization code directly with TikTok.
/// - Only ONE single POST request is sent per authorization code (no endpoint looping or retries).
class TikTokBackendService {
  TikTokBackendService._internal();
  static final TikTokBackendService instance = TikTokBackendService._internal();

  /// Submits the TikTok `code` and `codeVerifier` to the canonical authenticated Laravel endpoint:
  /// `POST /ar/mobile/social/tiktok/connect-token`
  Future<TikTokBackendConnectResult> connectTikTokCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
    required String state,
    Set<String> grantedScopes = const {},
    required String csrfToken,
    required String cookieHeader,
    http.Client? httpClient,
  }) async {
    final String platform = Platform.isIOS ? 'ios' : 'android';
    final Uri endpoint = Uri.parse(
      '${AppConstants.defaultWebsiteUrl}${AppConstants.tiktokConnectTokenPath}',
    );

    final Map<String, dynamic> bodyPayload = {
      'provider': 'tiktok',
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      'state': state,
      'granted_scopes': grantedScopes.toList(),
      'device_platform': platform,
    };

    final Map<String, String> headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest',
      if (csrfToken.isNotEmpty) 'X-CSRF-TOKEN': csrfToken,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };

    final http.Client client = httpClient ?? http.Client();
    try {
      final http.Response response = await client
          .post(
            endpoint,
            headers: headers,
            body: jsonEncode(bodyPayload),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return parseSuccessResponse(response.body);
      } else {
        return parseErrorResponse(response);
      }
    } on TimeoutException {
      return const TikTokBackendConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorCode: 'NETWORK_TIMEOUT',
        errorMessage: 'انتهت مهلة الاتصال بخادم باستيل أثناء التحقق من حساب تيك توك.',
      );
    } catch (_) {
      return const TikTokBackendConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorCode: 'NETWORK_ERROR',
        errorMessage: 'تعذر الاتصال بخادم باستيل للتحقق من حساب تيك توك.',
      );
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  /// Validates the exact documented Laravel success response schema:
  /// ```json
  /// {
  ///   "status": "success",
  ///   "connection_id": "tiktok_conn_123",
  ///   "provider": "tiktok",
  ///   "connected_account": {
  ///     "open_id": "_000...",
  ///     "display_name": "Pastel Studio",
  ///     "avatar_url": "https://..."
  ///   }
  /// }
  /// ```
  /// Never fabricates connection IDs or account identity when mandatory fields are missing.
  TikTokBackendConnectResult parseSuccessResponse(String responseBody) {
    try {
      final dynamic decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        return const TikTokBackendConnectResult(
          isSuccess: false,
          status: 'backend_error',
          errorCode: 'INVALID_RESPONSE_SCHEMA',
          errorMessage: 'استجابة غير صالحة من الخادم.',
        );
      }

      final Map<String, dynamic> data = decoded;
      final String? status = data['status']?.toString();

      if (status != 'success') {
        return TikTokBackendConnectResult(
          isSuccess: false,
          status: _mapErrorCodeToStatus(data['code']?.toString(), 200),
          errorCode: data['code']?.toString(),
          errorMessage: data['message']?.toString() ?? 'فشل ربط حساب تيك توك من الخادم.',
        );
      }

      final String? provider = data['provider']?.toString();
      if (provider != null && provider != 'tiktok') {
        return const TikTokBackendConnectResult(
          isSuccess: false,
          status: 'backend_error',
          errorCode: 'PROVIDER_MISMATCH',
          errorMessage: 'عدم تطابق مزود الخدمة في استجابة الخادم.',
        );
      }

      final String? connectionId = data['connection_id']?.toString().trim();
      final dynamic rawAccount = data['connected_account'];

      if (connectionId == null ||
          connectionId.isEmpty ||
          rawAccount is! Map<String, dynamic>) {
        return const TikTokBackendConnectResult(
          isSuccess: false,
          status: 'backend_error',
          errorCode: 'MISSING_MANDATORY_FIELDS',
          errorMessage: 'لم يُرجع الخادم معرّف الربط (connection_id) أو بيانات الحساب الموثقة (connected_account).',
        );
      }

      final Map<String, dynamic> account = rawAccount;
      final String? openId = account['open_id']?.toString().trim();
      final String? displayName = account['display_name']?.toString().trim();
      final String? avatarUrl = account['avatar_url']?.toString().trim();

      if (openId == null || openId.isEmpty || displayName == null || displayName.isEmpty) {
        return const TikTokBackendConnectResult(
          isSuccess: false,
          status: 'backend_error',
          errorCode: 'INCOMPLETE_ACCOUNT_IDENTITY',
          errorMessage: 'بيانات حساب تيك توك المستلمة من الخادم غير مكتملة (open_id / display_name).',
        );
      }

      return TikTokBackendConnectResult(
        isSuccess: true,
        status: 'success',
        connectionId: connectionId,
        openId: openId,
        displayName: displayName,
        avatarUrl: (avatarUrl != null && avatarUrl.isNotEmpty) ? avatarUrl : null,
      );
    } catch (_) {
      return const TikTokBackendConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorCode: 'JSON_PARSE_ERROR',
        errorMessage: 'خطأ في معالجة استجابة الخادم.',
      );
    }
  }

  /// Parses error responses according to the backend's explicit `code` contract
  /// rather than classifying every HTTP 422 as `permission_denied`.
  TikTokBackendConnectResult parseErrorResponse(http.Response response) {
    try {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final String? errorCode =
            (decoded['code'] ?? decoded['error_code'])?.toString().trim();
        final String? message = decoded['message']?.toString().trim();
        final String mappedStatus = _mapErrorCodeToStatus(errorCode, response.statusCode);

        return TikTokBackendConnectResult(
          isSuccess: false,
          status: mappedStatus,
          errorCode: errorCode,
          errorMessage: (message != null && message.isNotEmpty)
              ? message
              : 'استجاب السيرفر برمز خطأ (${response.statusCode}).',
        );
      }
    } catch (_) {}

    return TikTokBackendConnectResult(
      isSuccess: false,
      status: _mapErrorCodeToStatus(null, response.statusCode),
      errorCode: 'HTTP_${response.statusCode}',
      errorMessage: 'استجاب السيرفر برمز خطأ (${response.statusCode}).',
    );
  }

  String _mapErrorCodeToStatus(String? errorCode, int httpStatus) {
    switch (errorCode) {
      case 'MISSING_PERMISSIONS':
      case 'PERMISSION_DENIED':
      case 'INSUFFICIENT_SCOPES':
        return 'permission_denied';
      case 'INVALID_GRANT':
      case 'TIKTOK_TOKEN_EXCHANGE_FAILED':
      case 'INVALID_CODE_VERIFIER':
      case 'UNAUTHENTICATED':
        return 'authentication_failed';
      case 'ACCOUNT_ALREADY_LINKED':
        return 'account_already_linked';
      default:
        if (httpStatus == 401 || httpStatus == 403) {
          return 'authentication_failed';
        }
        if (httpStatus == 409) {
          return 'account_already_linked';
        }
        return 'backend_error';
    }
  }
}
