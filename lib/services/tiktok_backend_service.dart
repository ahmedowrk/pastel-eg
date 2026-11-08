import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

/// Represents the response returned by the Pastel Laravel backend after
/// verifying and exchanging a native TikTok authorization code + PKCE verifier.
class TikTokBackendConnectResult {
  final bool isSuccess;
  final String status; // 'success', 'permission_denied', 'backend_error'
  final String? connectionId;
  final String? openId;
  final String? displayName;
  final String? avatarUrl;
  final String? errorMessage;

  const TikTokBackendConnectResult({
    required this.isSuccess,
    required this.status,
    this.connectionId,
    this.openId,
    this.displayName,
    this.avatarUrl,
    this.errorMessage,
  });

  Map<String, dynamic> toBridgePayload(String requestId) {
    if (isSuccess) {
      return {
        'version': 1,
        'requestId': requestId,
        'provider': 'tiktok',
        'status': 'success',
        'connectionId': connectionId,
        'connectedAccount': {
          if (openId != null) 'openId': openId,
          if (displayName != null) 'displayName': displayName,
          if (avatarUrl != null) 'avatarUrl': avatarUrl,
        },
        'message': 'تم ربط حساب تيك توك بنجاح',
      };
    } else {
      return {
        'version': 1,
        'requestId': requestId,
        'provider': 'tiktok',
        'status': status,
        'errorMessage': errorMessage ?? 'فشل التحقق من ربط حساب تيك توك مع الخادم.',
      };
    }
  }
}

/// Service responsible for securely sending the TikTok authorization code and
/// PKCE code_verifier to the Pastel Laravel backend (`https://pastel-eg.com`).
///
/// The mobile client NEVER holds the TikTok Client Secret and NEVER exchanges
/// the authorization code directly with TikTok servers.
class TikTokBackendService {
  TikTokBackendService._internal();
  static final TikTokBackendService instance = TikTokBackendService._internal();

  /// Submits the TikTok `code` and `codeVerifier` to the authenticated Laravel session.
  Future<TikTokBackendConnectResult> connectTikTokCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
    String? state,
    Set<String> grantedScopes = const {},
    required String csrfToken,
    required String cookieHeader,
  }) async {
    final String platform = Platform.isIOS ? 'ios' : 'android';

    final Map<String, dynamic> bodyPayload = {
      'provider': 'tiktok',
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      if (state != null) 'state': state,
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

    final List<String> endpointPaths = [
      AppConstants.tiktokConnectTokenPath,
      AppConstants.tiktokFallbackConnectTokenPath,
      AppConstants.tiktokLegacyConnectTokenPath,
      AppConstants.tiktokMobileConnectTokenPath,
    ];

    http.Response? lastResponse;
    for (final String path in endpointPaths) {
      final Uri uri = Uri.parse('${AppConstants.defaultWebsiteUrl}$path');
      try {
        final http.Response response = await http
            .post(
              uri,
              headers: headers,
              body: jsonEncode(bodyPayload),
            )
            .timeout(const Duration(seconds: 20));

        lastResponse = response;

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return _parseSuccessResponse(response.body);
        }

        if (response.statusCode != 404 && response.statusCode != 405) {
          return _parseErrorResponse(response);
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[TikTokBackendService] Network error on $path: $e');
        }
      }
    }

    if (lastResponse != null) {
      return _parseErrorResponse(lastResponse);
    }

    return const TikTokBackendConnectResult(
      isSuccess: false,
      status: 'backend_error',
      errorMessage: 'تعذر الاتصال بخادم باستيل للتحقق من حساب تيك توك.',
    );
  }

  TikTokBackendConnectResult _parseSuccessResponse(String responseBody) {
    try {
      final Map<String, dynamic> data = jsonDecode(responseBody);
      final bool isOk = data['success'] == true || data['status'] == 'success';

      if (isOk) {
        final Map<String, dynamic>? account = (data['data'] is Map<String, dynamic>)
            ? data['data'] as Map<String, dynamic>
            : (data['connected_account'] is Map<String, dynamic>)
                ? data['connected_account'] as Map<String, dynamic>
                : (data['account'] is Map<String, dynamic>)
                    ? data['account'] as Map<String, dynamic>
                    : null;

        return TikTokBackendConnectResult(
          isSuccess: true,
          status: 'success',
          connectionId: data['connection_id']?.toString() ??
              account?['account_id']?.toString() ??
              'tiktok_${DateTime.now().millisecondsSinceEpoch}',
          openId: account?['open_id']?.toString() ??
              account?['account_id']?.toString() ??
              data['open_id']?.toString(),
          displayName: account?['display_name']?.toString() ?? data['display_name']?.toString(),
          avatarUrl: account?['avatar_url']?.toString() ?? data['avatar_url']?.toString(),
        );
      } else {
        return TikTokBackendConnectResult(
          isSuccess: false,
          status: 'permission_denied',
          errorMessage: data['message']?.toString() ?? 'فشل ربط حساب تيك توك من الخادم.',
        );
      }
    } catch (e) {
      return const TikTokBackendConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorMessage: 'خطأ في معالجة استجابة الخادم.',
      );
    }
  }

  TikTokBackendConnectResult _parseErrorResponse(http.Response response) {
    try {
      final Map<String, dynamic> err = jsonDecode(response.body);
      return TikTokBackendConnectResult(
        isSuccess: false,
        status: response.statusCode == 422 ? 'permission_denied' : 'backend_error',
        errorMessage:
            err['message']?.toString() ?? 'استجاب السيرفر برمز خطأ (${response.statusCode}).',
      );
    } catch (_) {
      return TikTokBackendConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorMessage: 'استجاب السيرفر برمز خطأ (${response.statusCode}).',
      );
    }
  }
}
