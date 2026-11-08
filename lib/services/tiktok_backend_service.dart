import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

/// Clean result returned from Laravel backend after completing TikTok code exchange.
class TikTokBackendConnectResult {
  final bool isSuccess;
  final String status; // 'success' | 'permission_denied' | 'backend_error'
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
    return {
      'version': 1,
      'requestId': requestId,
      'provider': 'tiktok',
      'status': status,
      if (connectionId != null) 'connectionId': connectionId,
      if (displayName != null) 'displayName': displayName,
      if (openId != null) 'openId': openId,
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
      if (errorMessage != null) 'errorMessage': errorMessage,
    };
  }
}

/// Service that securely transmits the TikTok Authorization Code and PKCE verifier
/// to the Laravel backend for server-to-server token exchange and database persistence.
///
/// Security:
/// - Never holds or requests TikTok Client Secret.
/// - Never passes access tokens or refresh tokens into JavaScript / DOM.
/// - Submits PKCE code_verifier so Laravel can complete the token exchange with TikTok APIs.
class TikTokBackendService {
  TikTokBackendService._internal();
  static final TikTokBackendService instance = TikTokBackendService._internal();

  /// Communicates with Laravel endpoint to exchange native TikTok authorization code
  /// for a persistent server-side account connection.
  Future<TikTokBackendConnectResult> connectTikTokCode({
    required String code,
    required String codeVerifier,
    required String state,
    required String redirectUri,
    required String csrfToken,
    required String cookieHeader,
  }) async {
    // Primary URL matches Laravel Provider Automation routes; fallback matches mobile namespace
    final Uri primaryEndpoint = Uri.parse(
      '${AppConstants.defaultWebsiteUrl}${AppConstants.tiktokConnectTokenPath}',
    );
    final Uri fallbackEndpoint = Uri.parse(
      '${AppConstants.defaultWebsiteUrl}${AppConstants.tiktokMobileConnectTokenPath}',
    );

    final Map<String, String> headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-CSRF-TOKEN': csrfToken,
      'X-Requested-With': 'XMLHttpRequest',
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };

    final Map<String, dynamic> body = {
      'provider': 'tiktok',
      'code': code,
      'code_verifier': codeVerifier,
      'state': state,
      'redirect_uri': redirectUri,
      'device_platform': Platform.isAndroid ? 'android' : 'ios',
    };

    final String encodedBody = jsonEncode(body);

    // Try primary endpoint first
    try {
      final response = await http
          .post(primaryEndpoint, headers: headers, body: encodedBody)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _parseSuccessResponse(response.body);
      } else if (response.statusCode == 404) {
        // Fallback to mobile endpoint if primary route is 404
        if (kDebugMode) {
          debugPrint('[TikTokBackendService] Primary endpoint 404, trying fallback...');
        }
        return await _sendFallbackRequest(fallbackEndpoint, headers, encodedBody);
      } else {
        return _parseErrorResponse(response);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TikTokBackendService] Network error on primary endpoint: $e');
      }
      return await _sendFallbackRequest(fallbackEndpoint, headers, encodedBody);
    }
  }

  Future<TikTokBackendConnectResult> _sendFallbackRequest(
    Uri endpoint,
    Map<String, String> headers,
    String body,
  ) async {
    try {
      final response = await http
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _parseSuccessResponse(response.body);
      } else {
        return _parseErrorResponse(response);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TikTokBackendService] Network error on fallback endpoint: $e');
      }
      return const TikTokBackendConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorMessage: 'تعذر الاتصال بخادم باستيل للتحقق من حساب تيك توك.',
      );
    }
  }

  TikTokBackendConnectResult _parseSuccessResponse(String responseBody) {
    try {
      final Map<String, dynamic> data = jsonDecode(responseBody);
      final String status = data['status'] ?? 'success';

      if (status == 'success') {
        final Map<String, dynamic>? account = data['connected_account'] ?? data['account'];
        return TikTokBackendConnectResult(
          isSuccess: true,
          status: 'success',
          connectionId: data['connection_id']?.toString() ??
              'tiktok_${DateTime.now().millisecondsSinceEpoch}',
          openId: account?['open_id']?.toString() ?? data['open_id']?.toString(),
          displayName: account?['display_name']?.toString() ?? data['display_name']?.toString(),
          avatarUrl: account?['avatar_url']?.toString() ?? data['avatar_url']?.toString(),
        );
      } else {
        return TikTokBackendConnectResult(
          isSuccess: false,
          status: 'permission_denied',
          errorMessage: data['message'] ?? 'فشل ربط حساب تيك توك من الخادم.',
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
        errorMessage: err['message'] ?? 'استجاب السيرفر برمز خطأ (${response.statusCode}).',
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
