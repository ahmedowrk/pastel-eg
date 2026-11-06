import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

/// Clean result returned from Laravel backend after validating native token.
class BackendSocialConnectResult {
  final bool isSuccess;
  final String status; // 'success' | 'permission_denied' | 'backend_error'
  final String? connectionId;
  final String? pageId;
  final String? pageName;
  final String? instagramUsername;
  final String? errorMessage;

  const BackendSocialConnectResult({
    required this.isSuccess,
    required this.status,
    this.connectionId,
    this.pageId,
    this.pageName,
    this.instagramUsername,
    this.errorMessage,
  });

  Map<String, dynamic> toBridgePayload(String requestId, String provider) {
    return {
      'version': 1,
      'requestId': requestId,
      'provider': provider,
      'status': status,
      if (connectionId != null) 'connectionId': connectionId,
      if (pageName != null) 'pageName': pageName,
      if (pageId != null) 'pageId': pageId,
      if (instagramUsername != null) 'instagramUsername': instagramUsername,
      if (errorMessage != null) 'errorMessage': errorMessage,
    };
  }
}

/// Service that securely transmits native credentials to Laravel without
/// exposing tokens to the WebView.
class SocialBackendService {
  SocialBackendService._internal();
  static final SocialBackendService instance = SocialBackendService._internal();

  /// Communicates with Laravel endpoint to exchange native Facebook token
  /// for a persistent server-side connection and Page selection.
  Future<BackendSocialConnectResult> connectMetaToken({
    required String accessToken,
    required Set<String> grantedPermissions,
    required String csrfToken,
    required String cookieHeader,
  }) async {
    final Uri endpoint = Uri.parse(
      '${AppConstants.defaultWebsiteUrl}/ar/mobile/social/meta/connect-token',
    );

    try {
      final response = await http.post(
        endpoint,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-TOKEN': csrfToken,
          'X-Requested-With': 'XMLHttpRequest',
          if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
        },
        body: jsonEncode({
          'provider': 'facebook',
          'access_token': accessToken,
          'granted_permissions': grantedPermissions.toList(),
          'device_platform': Platform.isAndroid ? 'android' : 'ios',
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final String status = data['status'] ?? 'success';

        if (status == 'success') {
          final Map<String, dynamic>? page = data['connected_page'];
          final Map<String, dynamic>? ig = page?['instagram_account'];

          return BackendSocialConnectResult(
            isSuccess: true,
            status: 'success',
            connectionId: data['connection_id']?.toString() ?? 'conn_${DateTime.now().millisecondsSinceEpoch}',
            pageId: page?['id']?.toString(),
            pageName: page?['name']?.toString(),
            instagramUsername: ig?['username']?.toString(),
          );
        } else {
          return BackendSocialConnectResult(
            isSuccess: false,
            status: 'permission_denied',
            errorMessage: data['message'] ?? 'فشل ربط الحساب بسبب نقص الصلاحيات.',
          );
        }
      } else if (response.statusCode == 422) {
        final Map<String, dynamic> err = jsonDecode(response.body);
        return BackendSocialConnectResult(
          isSuccess: false,
          status: 'permission_denied',
          errorMessage: err['message'] ?? 'صلاحيات فيسبوك المطلوبة غير مكتملة.',
        );
      } else {
        return BackendSocialConnectResult(
          isSuccess: false,
          status: 'backend_error',
          errorMessage: 'استجاب السيرفر برمز خطأ (${response.statusCode}).',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SocialBackendService] Network error: $e');
      }
      return BackendSocialConnectResult(
        isSuccess: false,
        status: 'backend_error',
        errorMessage: 'تعذر الاتصال بسيرفر باستيل للتحقق من الحساب.',
      );
    }
  }
}
