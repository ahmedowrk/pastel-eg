import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Status of the native Google account selection step.
enum YouTubeAccountSelectionStatus {
  selected,
  cancelled,
  noAccountsOnDevice,
  error,
}

/// Result returned by the native Google Account Picker (Credential Manager /
/// system AccountPicker on Android, or iOS account chooser).
@immutable
class YouTubeAccountSelectionResult {
  final YouTubeAccountSelectionStatus status;
  final String? email;
  final String? displayName;
  final String? profilePictureUri;
  final String? idToken;
  final String? selectionSource;
  final String? errorCode;
  final String? errorMessage;

  const YouTubeAccountSelectionResult({
    required this.status,
    this.email,
    this.displayName,
    this.profilePictureUri,
    this.idToken,
    this.selectionSource,
    this.errorCode,
    this.errorMessage,
  });

  bool get isSelected =>
      status == YouTubeAccountSelectionStatus.selected &&
      email != null &&
      email!.trim().isNotEmpty;

  bool get isCancelled => status == YouTubeAccountSelectionStatus.cancelled;

  factory YouTubeAccountSelectionResult.fromMap(Map<dynamic, dynamic> map) {
    final rawStatus = (map['status'] as String? ?? 'error').toLowerCase();
    final YouTubeAccountSelectionStatus parsedStatus;
    switch (rawStatus) {
      case 'selected':
        parsedStatus = YouTubeAccountSelectionStatus.selected;
        break;
      case 'cancelled':
        parsedStatus = YouTubeAccountSelectionStatus.cancelled;
        break;
      case 'no_accounts':
      case 'noaccountsondevice':
        parsedStatus = YouTubeAccountSelectionStatus.noAccountsOnDevice;
        break;
      default:
        parsedStatus = YouTubeAccountSelectionStatus.error;
    }

    return YouTubeAccountSelectionResult(
      status: parsedStatus,
      email: (map['email'] as String?)?.trim(),
      displayName: (map['displayName'] as String?)?.trim(),
      profilePictureUri: (map['profilePictureUri'] as String?)?.trim(),
      idToken: map['idToken'] as String?,
      selectionSource: map['selectionSource'] as String?,
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'status': status.name,
        'email': email,
        'displayName': displayName,
        'profilePictureUri': profilePictureUri,
        'idToken': idToken,
        'selectionSource': selectionSource,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
      };
}

/// Status of the native YouTube OAuth scope authorization step.
enum YouTubeAuthorizationStatus {
  authorized,
  cancelled,
  denied,
  error,
}

/// Result returned by the native YouTube OAuth authorization step
/// (`AuthorizationClient` on Android / OAuth session on iOS).
@immutable
class YouTubeAuthorizationResult {
  final YouTubeAuthorizationStatus status;
  final String? selectedAccountEmail;
  final String? accessToken;
  final String? serverAuthCode;
  final List<String> grantedScopes;
  final int? expiresAtEpochMs;
  final String? errorCode;
  final String? errorMessage;

  const YouTubeAuthorizationResult({
    required this.status,
    this.selectedAccountEmail,
    this.accessToken,
    this.serverAuthCode,
    this.grantedScopes = const <String>[],
    this.expiresAtEpochMs,
    this.errorCode,
    this.errorMessage,
  });

  bool get isAuthorized =>
      status == YouTubeAuthorizationStatus.authorized &&
      accessToken != null &&
      accessToken!.trim().isNotEmpty;

  bool get isCancelled => status == YouTubeAuthorizationStatus.cancelled;

  bool get isDenied => status == YouTubeAuthorizationStatus.denied;

  factory YouTubeAuthorizationResult.fromMap(Map<dynamic, dynamic> map) {
    final rawStatus = (map['status'] as String? ?? 'error').toLowerCase();
    final YouTubeAuthorizationStatus parsedStatus;
    switch (rawStatus) {
      case 'authorized':
        parsedStatus = YouTubeAuthorizationStatus.authorized;
        break;
      case 'cancelled':
        parsedStatus = YouTubeAuthorizationStatus.cancelled;
        break;
      case 'denied':
        parsedStatus = YouTubeAuthorizationStatus.denied;
        break;
      default:
        parsedStatus = YouTubeAuthorizationStatus.error;
    }

    final rawScopes = map['grantedScopes'];
    final List<String> parsedScopes = rawScopes is List
        ? rawScopes
            .map((e) => e?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final rawExpires = map['expiresAtEpochMs'];
    final int? expiresAt = rawExpires is int
        ? rawExpires
        : (rawExpires is num ? rawExpires.toInt() : null);

    return YouTubeAuthorizationResult(
      status: parsedStatus,
      selectedAccountEmail: (map['selectedAccountEmail'] as String?)?.trim(),
      accessToken: (map['accessToken'] as String?)?.trim(),
      serverAuthCode: (map['serverAuthCode'] as String?)?.trim(),
      grantedScopes: parsedScopes,
      expiresAtEpochMs: expiresAt,
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'status': status.name,
        'selectedAccountEmail': selectedAccountEmail,
        'accessToken': accessToken,
        'serverAuthCode': serverAuthCode,
        'grantedScopes': grantedScopes,
        'expiresAtEpochMs': expiresAtEpochMs,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
      };
}

/// Abstract platform contract for isolated YouTube authentication.
///
/// Completely decoupled from Meta (`FacebookAuthService` / `SocialBridgeService`).
abstract class YouTubeAuthPlatform {
  static YouTubeAuthPlatform _instance = MethodChannelYouTubeAuthPlatform();

  static YouTubeAuthPlatform get instance => _instance;

  /// Allows injecting a mock or fake platform implementation in unit tests.
  @visibleForTesting
  static set instance(YouTubeAuthPlatform value) {
    _instance = value;
  }

  /// Launches the native Google account selector on the device.
  ///
  /// [filterByAuthorizedAccounts] MUST default to `false` so the user can pick
  /// ANY Google/Gmail account present on the device, even if it has never been
  /// used with Pastel before.
  Future<YouTubeAccountSelectionResult> pickGoogleAccount({
    required String serverClientId,
    bool filterByAuthorizedAccounts = false,
    bool forceAccountSelection = true,
  });

  /// Requests YouTube OAuth scopes (`youtube.upload`, `youtube.force-ssl`, etc.)
  /// specifically bound to [accountEmail].
  Future<YouTubeAuthorizationResult> authorizeYouTubeScopes({
    required String accountEmail,
    required String serverClientId,
    required List<String> scopes,
    bool forceCodeForRefreshToken = true,
  });

  /// Clears any cached Google credential selection state so switching accounts
  /// always presents the full account chooser cleanly.
  Future<void> clearSelectedAccountSession({String? accountEmail});
}

/// Default [MethodChannel] implementation communicating with
/// `YouTubeAuthPlugin.kt` (Android) and `YouTubeAuthPlugin.swift` (iOS).
class MethodChannelYouTubeAuthPlatform extends YouTubeAuthPlatform {
  static const MethodChannel _channel = MethodChannel(
    'com.pasteleg.app/youtube_auth',
  );

  @override
  Future<YouTubeAccountSelectionResult> pickGoogleAccount({
    required String serverClientId,
    bool filterByAuthorizedAccounts = false,
    bool forceAccountSelection = true,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'pickGoogleAccount',
        <String, dynamic>{
          'serverClientId': serverClientId,
          'filterByAuthorizedAccounts': filterByAuthorizedAccounts,
          'forceAccountSelection': forceAccountSelection,
        },
      );
      if (result == null) {
        return const YouTubeAccountSelectionResult(
          status: YouTubeAccountSelectionStatus.error,
          errorCode: 'null_platform_response',
          errorMessage: 'لم يتم استلام استجابة من نظام اختيار حسابات Google.',
        );
      }
      return YouTubeAccountSelectionResult.fromMap(result);
    } on PlatformException catch (e) {
      if (e.code == 'cancelled' || e.code == 'USER_CANCELLED') {
        return YouTubeAccountSelectionResult(
          status: YouTubeAccountSelectionStatus.cancelled,
          errorCode: e.code,
          errorMessage: e.message ?? 'تم إلغاء اختيار حساب Google.',
        );
      }
      if (e.code == 'no_accounts' || e.code == 'NO_ACCOUNTS') {
        return YouTubeAccountSelectionResult(
          status: YouTubeAccountSelectionStatus.noAccountsOnDevice,
          errorCode: e.code,
          errorMessage:
              e.message ?? 'لا يوجد أي حساب Google مسجل الدخول على هذا الجهاز.',
        );
      }
      return YouTubeAccountSelectionResult(
        status: YouTubeAccountSelectionStatus.error,
        errorCode: e.code,
        errorMessage: e.message ?? 'تعذر فتح نافذة اختيار حسابات Google.',
      );
    } catch (e) {
      return YouTubeAccountSelectionResult(
        status: YouTubeAccountSelectionStatus.error,
        errorCode: 'unexpected_platform_error',
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Future<YouTubeAuthorizationResult> authorizeYouTubeScopes({
    required String accountEmail,
    required String serverClientId,
    required List<String> scopes,
    bool forceCodeForRefreshToken = true,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'authorizeYouTubeScopes',
        <String, dynamic>{
          'accountEmail': accountEmail,
          'serverClientId': serverClientId,
          'scopes': scopes,
          'forceCodeForRefreshToken': forceCodeForRefreshToken,
        },
      );
      if (result == null) {
        return const YouTubeAuthorizationResult(
          status: YouTubeAuthorizationStatus.error,
          errorCode: 'null_authorization_response',
          errorMessage: 'لم يتم استلام استجابة من خدمة تفويض صلاحيات YouTube.',
        );
      }
      return YouTubeAuthorizationResult.fromMap(result);
    } on PlatformException catch (e) {
      if (e.code == 'cancelled' || e.code == 'USER_CANCELLED') {
        return YouTubeAuthorizationResult(
          status: YouTubeAuthorizationStatus.cancelled,
          selectedAccountEmail: accountEmail,
          errorCode: e.code,
          errorMessage: e.message ?? 'تم إلغاء تفويض صلاحيات YouTube.',
        );
      }
      if (e.code == 'access_denied' || e.code == 'PERMISSION_DENIED') {
        return YouTubeAuthorizationResult(
          status: YouTubeAuthorizationStatus.denied,
          selectedAccountEmail: accountEmail,
          errorCode: e.code,
          errorMessage:
              e.message ?? 'تم رفض منح صلاحيات الوصول إلى قناة YouTube.',
        );
      }
      return YouTubeAuthorizationResult(
        status: YouTubeAuthorizationStatus.error,
        selectedAccountEmail: accountEmail,
        errorCode: e.code,
        errorMessage: e.message ?? 'فشل تفويض صلاحيات YouTube.',
      );
    } catch (e) {
      return YouTubeAuthorizationResult(
        status: YouTubeAuthorizationStatus.error,
        selectedAccountEmail: accountEmail,
        errorCode: 'unexpected_authorization_error',
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Future<void> clearSelectedAccountSession({String? accountEmail}) async {
    try {
      await _channel.invokeMethod<void>(
        'clearSelectedAccountSession',
        <String, dynamic>{
          if (accountEmail != null) 'accountEmail': accountEmail,
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[YouTubeAuthPlatform] clearSelectedAccountSession error: $e');
      }
    }
  }
}
