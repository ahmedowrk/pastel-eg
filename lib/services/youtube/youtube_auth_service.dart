import 'package:flutter/foundation.dart';

import '../../platform/youtube/youtube_auth_platform.dart';

/// Outcome of the complete Google Account Selection + YouTube OAuth flow.
enum YouTubeAuthFlowOutcome {
  authorized,
  cancelledAccountSelection,
  noGoogleAccountsOnDevice,
  cancelledPermissionConsent,
  permissionDenied,
  accountMismatchError,
  error,
}

/// Complete, strongly-typed result of [YouTubeAuthService].
@immutable
class YouTubeAuthSession {
  final YouTubeAuthFlowOutcome outcome;
  final String? selectedEmail;
  final String? displayName;
  final String? profilePictureUri;
  final String? accessToken;
  final String? serverAuthCode;
  final List<String> grantedScopes;
  final DateTime? expiresAt;
  final String? errorCode;
  final String? errorMessage;

  const YouTubeAuthSession({
    required this.outcome,
    this.selectedEmail,
    this.displayName,
    this.profilePictureUri,
    this.accessToken,
    this.serverAuthCode,
    this.grantedScopes = const <String>[],
    this.expiresAt,
    this.errorCode,
    this.errorMessage,
  });

  bool get isAuthorized =>
      outcome == YouTubeAuthFlowOutcome.authorized &&
      selectedEmail != null &&
      selectedEmail!.isNotEmpty &&
      accessToken != null &&
      accessToken!.isNotEmpty;

  bool get isCancelled =>
      outcome == YouTubeAuthFlowOutcome.cancelledAccountSelection ||
      outcome == YouTubeAuthFlowOutcome.cancelledPermissionConsent;

  bool get isTokenExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(
      expiresAt!.subtract(const Duration(seconds: 60)),
    );
  }
}

/// Isolated YouTube Authentication & OAuth Authorization Service.
///
/// NOTE: Completely isolated from Meta (`FacebookAuthService` / `SocialBridgeService`).
class YouTubeAuthService {
  YouTubeAuthService._internal({YouTubeAuthPlatform? platform})
      : _platform = platform;

  static final YouTubeAuthService instance = YouTubeAuthService._internal();

  @visibleForTesting
  factory YouTubeAuthService.forTesting({
    required YouTubeAuthPlatform platform,
  }) {
    return YouTubeAuthService._internal(platform: platform);
  }

  final YouTubeAuthPlatform? _platform;

  YouTubeAuthPlatform get _authPlatform =>
      _platform ?? YouTubeAuthPlatform.instance;

  static const String kPastelYouTubeWebClientId =
      '706271758182-ulnkh7jtinp6ar7r8olqnoipnntullve.apps.googleusercontent.com';

  static const List<String> kRequiredYouTubeScopes = <String>[
    'https://www.googleapis.com/auth/youtube.upload',
    'https://www.googleapis.com/auth/youtube.force-ssl',
  ];

  static const String kYouTubeReadonlyScope =
      'https://www.googleapis.com/auth/youtube.readonly';

  bool _isAuthInProgress = false;
  YouTubeAuthSession? _lastAuthorizedSession;

  bool get isAuthInProgress => _isAuthInProgress;
  YouTubeAuthSession? get lastAuthorizedSession => _lastAuthorizedSession;

  Future<YouTubeAccountSelectionResult> pickDeviceGoogleAccount({
    String serverClientId = kPastelYouTubeWebClientId,
    bool switchAccount = false,
  }) async {
    if (switchAccount) {
      await _authPlatform.clearSelectedAccountSession(
        accountEmail: _lastAuthorizedSession?.selectedEmail,
      );
      _lastAuthorizedSession = null;
    }

    return _authPlatform.pickGoogleAccount(
      serverClientId: serverClientId,
      filterByAuthorizedAccounts: false,
      forceAccountSelection: true,
    );
  }

  Future<YouTubeAuthSession> authorizeYouTubeForAccount({
    required YouTubeAccountSelectionResult selectedAccount,
    String serverClientId = kPastelYouTubeWebClientId,
    List<String> requestedScopes = kRequiredYouTubeScopes,
  }) async {
    final chosenEmail = selectedAccount.email?.trim() ?? '';
    if (!selectedAccount.isSelected || chosenEmail.isEmpty) {
      return const YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.error,
        errorCode: 'missing_selected_account',
        errorMessage: 'يرجى اختيار حساب Google صالح أولاً.',
      );
    }

    final authResult = await _authPlatform.authorizeYouTubeScopes(
      accountEmail: chosenEmail,
      serverClientId: serverClientId,
      scopes: requestedScopes,
      forceCodeForRefreshToken: true,
    );

    if (authResult.isCancelled) {
      return YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.cancelledPermissionConsent,
        selectedEmail: chosenEmail,
        displayName: selectedAccount.displayName,
        profilePictureUri: selectedAccount.profilePictureUri,
        errorCode: authResult.errorCode ?? 'cancelled_consent',
        errorMessage:
            authResult.errorMessage ?? 'تم إلغاء الموافقة على صلاحيات YouTube.',
      );
    }

    if (authResult.isDenied) {
      return YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.permissionDenied,
        selectedEmail: chosenEmail,
        displayName: selectedAccount.displayName,
        profilePictureUri: selectedAccount.profilePictureUri,
        errorCode: authResult.errorCode ?? 'permission_denied',
        errorMessage: authResult.errorMessage ??
            'تم رفض منح صلاحيات YouTube المطلوبة. لا يمكن إتمام ربط القناة بدون الموافقة على الصلاحيات.',
      );
    }

    if (!authResult.isAuthorized) {
      return YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.error,
        selectedEmail: chosenEmail,
        displayName: selectedAccount.displayName,
        profilePictureUri: selectedAccount.profilePictureUri,
        errorCode: authResult.errorCode ?? 'authorization_failed',
        errorMessage: authResult.errorMessage ??
            'تعذر الحصول على تصريح الوصول إلى YouTube للحساب المختار.',
      );
    }

    final returnedEmail = authResult.selectedAccountEmail?.trim();
    if (returnedEmail != null &&
        returnedEmail.isNotEmpty &&
        returnedEmail.toLowerCase() != chosenEmail.toLowerCase()) {
      return YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.accountMismatchError,
        selectedEmail: chosenEmail,
        errorCode: 'account_mismatch',
        errorMessage:
            'حدث تعارض بين الحساب المختار ($chosenEmail) والحساب الذي تم تفويضه ($returnedEmail). يرجى إعادة المحاولة.',
      );
    }

    if (authResult.grantedScopes.isNotEmpty &&
        !_hasRequiredYouTubeScopes(authResult.grantedScopes, requestedScopes)) {
      return YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.permissionDenied,
        selectedEmail: chosenEmail,
        displayName: selectedAccount.displayName,
        profilePictureUri: selectedAccount.profilePictureUri,
        grantedScopes: authResult.grantedScopes,
        errorCode: 'insufficient_scopes',
        errorMessage:
            'لم يتم منح كافة صلاحيات YouTube المطلوبة أثناء الموافقة. يرجى الموافقة على جميع الصلاحيات لإتمام الربط.',
      );
    }

    final expiresAt = authResult.expiresAtEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(authResult.expiresAtEpochMs!)
        : DateTime.now().add(const Duration(minutes: 55));

    final session = YouTubeAuthSession(
      outcome: YouTubeAuthFlowOutcome.authorized,
      selectedEmail: chosenEmail,
      displayName: selectedAccount.displayName,
      profilePictureUri: selectedAccount.profilePictureUri,
      accessToken: authResult.accessToken,
      serverAuthCode: authResult.serverAuthCode,
      grantedScopes: authResult.grantedScopes.isNotEmpty
          ? authResult.grantedScopes
          : requestedScopes,
      expiresAt: expiresAt,
    );

    _lastAuthorizedSession = session;
    return session;
  }

  Future<YouTubeAuthSession> authenticateAndAuthorize({
    String serverClientId = kPastelYouTubeWebClientId,
    List<String> requestedScopes = kRequiredYouTubeScopes,
    bool switchAccount = false,
    ValueChanged<String>? onStepChanged,
  }) async {
    if (_isAuthInProgress) {
      return const YouTubeAuthSession(
        outcome: YouTubeAuthFlowOutcome.error,
        errorCode: 'auth_in_progress',
        errorMessage: 'توجد عملية ربط حساب YouTube جارية بالفعل. يرجى الانتظار.',
      );
    }

    _isAuthInProgress = true;
    try {
      onStepChanged?.call('picking_account');
      final selection = await pickDeviceGoogleAccount(
        serverClientId: serverClientId,
        switchAccount: switchAccount,
      );

      if (selection.isCancelled) {
        return YouTubeAuthSession(
          outcome: YouTubeAuthFlowOutcome.cancelledAccountSelection,
          errorCode: selection.errorCode ?? 'cancelled_account_selection',
          errorMessage:
              selection.errorMessage ?? 'تم إلغاء اختيار حساب Google.',
        );
      }

      if (selection.status ==
          YouTubeAccountSelectionStatus.noAccountsOnDevice) {
        return YouTubeAuthSession(
          outcome: YouTubeAuthFlowOutcome.noGoogleAccountsOnDevice,
          errorCode: selection.errorCode ?? 'no_google_accounts',
          errorMessage: selection.errorMessage ??
              'لا توجد حسابات Google مسجلة على هذا الجهاز. يرجى إضافة حساب Google من إعدادات الجهاز أولاً.',
        );
      }

      if (!selection.isSelected) {
        return YouTubeAuthSession(
          outcome: YouTubeAuthFlowOutcome.error,
          errorCode: selection.errorCode ?? 'account_selection_failed',
          errorMessage:
              selection.errorMessage ?? 'تعذر اختيار حساب Google من الجهاز.',
        );
      }

      onStepChanged?.call('authorizing_youtube');
      return await authorizeYouTubeForAccount(
        selectedAccount: selection,
        serverClientId: serverClientId,
        requestedScopes: requestedScopes,
      );
    } finally {
      _isAuthInProgress = false;
    }
  }

  Future<void> clearSession() async {
    final previousEmail = _lastAuthorizedSession?.selectedEmail;
    _lastAuthorizedSession = null;
    await _authPlatform.clearSelectedAccountSession(
      accountEmail: previousEmail,
    );
  }

  bool _hasRequiredYouTubeScopes(
    List<String> grantedScopes,
    List<String> requestedScopes,
  ) {
    final normalizedGranted = grantedScopes
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();

    for (final req in requestedScopes) {
      final normalizedReq = req.trim().toLowerCase();
      if (!normalizedGranted.contains(normalizedReq)) {
        if (!normalizedGranted.contains(
          'https://www.googleapis.com/auth/youtube',
        )) {
          return false;
        }
      }
    }
    return true;
  }
}
