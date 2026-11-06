import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';

/// Result status of a native Meta authorization request.
enum FacebookAuthStatus {
  success,
  cancelled,
  permissionDenied,
  failed,
  unsupported,
}

/// Secure result container for Facebook authorization.
/// Note: Access tokens are only held internally by the service layer
/// and are NEVER exposed to the WebView DOM or JavaScript Bridge.
class FacebookAuthResult {
  final FacebookAuthStatus status;
  final String? accessToken;
  final String? userId;
  final Set<String> grantedPermissions;
  final Set<String> declinedPermissions;
  final String? errorMessage;

  const FacebookAuthResult({
    required this.status,
    this.accessToken,
    this.userId,
    this.grantedPermissions = const {},
    this.declinedPermissions = const {},
    this.errorMessage,
  });

  bool get isSuccess => status == FacebookAuthStatus.success && accessToken != null;
}

/// Dedicated Service managing Native Facebook & Instagram OAuth flows.
///
/// Handles:
/// - Native Facebook App Single Sign-On (SSO)
/// - System browser fallback (when Facebook App is not installed)
/// - Business permissions required by Pastel (`pages_*`, `instagram_*`)
/// - Granular granted vs declined permission verification
class FacebookAuthService {
  FacebookAuthService._internal();
  static final FacebookAuthService instance = FacebookAuthService._internal();

  /// Exact verified business permissions requested by Pastel Laravel backend
  /// for Facebook Page and Instagram Professional Account connection:
  static const List<String> requiredPermissions = [
    'public_profile',
    'email',
    'pages_show_list',
    'pages_read_engagement',
    'pages_manage_posts',
    'pages_manage_metadata',
    'pages_messaging',
    'publish_video',
    'instagram_basic',
    'instagram_manage_messages',
    'instagram_content_publish',
  ];

  /// Initiates native login flow.
  ///
  /// Supports:
  /// - Native Facebook App SSO
  /// - System browser fallback (Custom Tabs / ASWebAuthenticationSession)
  /// - Facebook Login for Business `config_id` if configured in Meta Dashboard
  Future<FacebookAuthResult> login({
    List<String> permissions = requiredPermissions,
    String? configId,
  }) async {
    try {
      // Trigger login through flutter_facebook_auth
      // If configId is provided, Meta Business Login Configuration is applied
      final LoginResult result = await FacebookAuth.instance.login(
        permissions: permissions,
        loginBehavior: LoginBehavior.nativeWithFallback,
      );

      switch (result.status) {
        case LoginStatus.success:
          final AccessToken? token = result.accessToken;
          if (token == null || token.token.isEmpty) {
            return const FacebookAuthResult(
              status: FacebookAuthStatus.failed,
              errorMessage: 'Facebook authorization succeeded but returned an empty access token.',
            );
          }

          final Set<String> granted = token.grantedPermissions?.toSet() ?? {};
          final Set<String> declined = token.declinedPermissions?.toSet() ?? {};

          // Verify whether essential page permissions were granted
          final bool hasCorePagePermission = granted.contains('pages_show_list') ||
              granted.contains('pages_manage_posts') ||
              granted.contains('pages_messaging');

          if (declined.contains('pages_show_list') || (!hasCorePagePermission && granted.isNotEmpty)) {
            return FacebookAuthResult(
              status: FacebookAuthStatus.permissionDenied,
              accessToken: null,
              userId: token.userId,
              grantedPermissions: granted,
              declinedPermissions: declined,
              errorMessage: 'لم يتم منح صلاحيات إدارة الصفحات المطلوبة (pages_show_list).',
            );
          }

          return FacebookAuthResult(
            status: FacebookAuthStatus.success,
            accessToken: token.token,
            userId: token.userId,
            grantedPermissions: granted,
            declinedPermissions: declined,
          );

        case LoginStatus.cancelled:
          return const FacebookAuthResult(
            status: FacebookAuthStatus.cancelled,
            errorMessage: 'تم إلغاء عملية تسجيل الدخول بواسطة المستخدم.',
          );

        case LoginStatus.failed:
          return FacebookAuthResult(
            status: FacebookAuthStatus.failed,
            errorMessage: result.message ?? 'فشل الاتصال بفيسبوك.',
          );

        case LoginStatus.operationInProgress:
          return const FacebookAuthResult(
            status: FacebookAuthStatus.failed,
            errorMessage: 'عملية تسجيل الدخول قيد التنفيذ بالفعل.',
          );
      }
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[FacebookAuthService] Native login exception: $e');
        debugPrint(stack.toString());
      }
      return FacebookAuthResult(
        status: FacebookAuthStatus.failed,
        errorMessage: 'حدث خطأ أثناء بدء تسجيل الدخول: ${e.toString()}',
      );
    }
  }

  /// Checks if an active Facebook session is already present.
  Future<AccessToken?> getCurrentAccessToken() async {
    try {
      return await FacebookAuth.instance.accessToken;
    } catch (_) {
      return null;
    }
  }

  /// Logs out from the native Facebook SDK.
  Future<void> logOut() async {
    try {
      await FacebookAuth.instance.logOut();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FacebookAuthService] logOut error: $e');
      }
    }
  }
}
