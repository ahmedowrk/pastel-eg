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
/// - Explicit declined-permission verification while deferring final Page/IG
///   granular_scopes validation to the Laravel backend.
class FacebookAuthService {
  FacebookAuthService._internal();
  static final FacebookAuthService instance = FacebookAuthService._internal();

  /// Exact verified business permissions requested by Pastel Laravel backend
  /// (/provider/automation-settings/provider/social-connections/meta/connect)
  /// for Facebook Page and Instagram Professional Account connection:
  static const List<String> requiredPermissions = [
    'public_profile',
    'pages_show_list',
    'pages_read_engagement',
    'pages_manage_metadata',
    'pages_manage_posts',
    'publish_video',
    'pages_messaging',
    'instagram_basic',
    'instagram_content_publish',
    'instagram_manage_messages',
  ];

  /// Core business scopes that must not be explicitly declined on the client.
  static const Set<String> _criticalBusinessPermissions = {
    'pages_show_list',
    'pages_read_engagement',
    'pages_manage_metadata',
    'pages_manage_posts',
    'pages_messaging',
    'instagram_basic',
    'instagram_content_publish',
    'instagram_manage_messages',
  };

  /// Initiates native login flow.
  ///
  /// Note: Acquiring an AccessToken here only completes client-side OAuth.
  /// Final connection status and Page/Instagram asset binding are only
  /// confirmed after Laravel validates the token via `/ar/mobile/social/meta/connect-token`.
  Future<FacebookAuthResult> login({
    List<String> permissions = requiredPermissions,
    String? configId,
  }) async {
    try {
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

          // Reject if any critical Page/Instagram permission was explicitly declined.
          // Do NOT reject merely because `granted` omits business scopes: in
          // Facebook Login for Business (facebook_login_for_business_uat),
          // native Android Katana SSO often returns only top-level user scopes
          // in `AccessToken.getPermissions()` while storing Page/Instagram
          // scopes in server-side `granular_scopes` verified by Laravel.
          final Set<String> declinedCritical =
              declined.intersection(_criticalBusinessPermissions);
          if (declinedCritical.isNotEmpty) {
            return FacebookAuthResult(
              status: FacebookAuthStatus.permissionDenied,
              accessToken: null,
              userId: token.userId,
              grantedPermissions: granted,
              declinedPermissions: declined,
              errorMessage:
                  'لم يتم منح الصلاحيات المطلوبة لربط الصفحة وحساب إنستغرام (${declinedCritical.join(', ')}).',
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
