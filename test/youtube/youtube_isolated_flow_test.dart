import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pastel/platform/youtube/youtube_auth_platform.dart';
import 'package:pastel/screens/youtube/youtube_connection_screen.dart';
import 'package:pastel/services/youtube/youtube_auth_service.dart';
import 'package:pastel/services/youtube/youtube_channel_service.dart';
import 'package:pastel/services/youtube/youtube_token_service.dart';

class FakeYouTubeAuthPlatform extends YouTubeAuthPlatform {
  bool? lastFilterByAuthorizedAccounts;
  bool? lastForceAccountSelection;
  String? clearedAccountEmail;
  int clearCallCount = 0;

  YouTubeAccountSelectionResult Function()? onPickAccount;
  Future<YouTubeAuthorizationResult> Function(
    String accountEmail,
    List<String> scopes,
  )? onAuthorize;

  @override
  Future<YouTubeAccountSelectionResult> pickGoogleAccount({
    required String serverClientId,
    bool filterByAuthorizedAccounts = false,
    bool forceAccountSelection = true,
  }) async {
    lastFilterByAuthorizedAccounts = filterByAuthorizedAccounts;
    lastForceAccountSelection = forceAccountSelection;
    if (onPickAccount != null) {
      return onPickAccount!();
    }
    return const YouTubeAccountSelectionResult(
      status: YouTubeAccountSelectionStatus.selected,
      email: 'new.creator@gmail.com',
      displayName: 'New Creator',
      selectionSource: 'credential_manager',
    );
  }

  @override
  Future<YouTubeAuthorizationResult> authorizeYouTubeScopes({
    required String accountEmail,
    required String serverClientId,
    required List<String> scopes,
    bool forceCodeForRefreshToken = true,
  }) async {
    if (onAuthorize != null) {
      return onAuthorize!(accountEmail, scopes);
    }
    return YouTubeAuthorizationResult(
      status: YouTubeAuthorizationStatus.authorized,
      selectedAccountEmail: accountEmail,
      accessToken: 'ya29.valid_token_for_$accountEmail',
      serverAuthCode: '4/0AeanS0_server_code',
      grantedScopes: scopes,
      expiresAtEpochMs:
          DateTime.now().add(const Duration(minutes: 55)).millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> clearSelectedAccountSession({String? accountEmail}) async {
    clearCallCount++;
    clearedAccountEmail = accountEmail;
  }
}

void main() {
  group('Isolated YouTube Account Selection & OAuth Flow', () {
    late FakeYouTubeAuthPlatform fakePlatform;
    late YouTubeAuthService authService;

    setUp(() {
      fakePlatform = FakeYouTubeAuthPlatform();
      authService = YouTubeAuthService.forTesting(platform: fakePlatform);
    });

    test(
      '1 & 3. Picks any Google account on device with filterByAuthorizedAccounts=false (supports accounts never used with Pastel)',
      () async {
        final session = await authService.authenticateAndAuthorize();

        expect(fakePlatform.lastFilterByAuthorizedAccounts, isFalse);
        expect(fakePlatform.lastForceAccountSelection, isTrue);
        expect(session.isAuthorized, isTrue);
        expect(session.selectedEmail, equals('new.creator@gmail.com'));
        expect(
          session.accessToken,
          equals('ya29.valid_token_for_new.creator@gmail.com'),
        );
      },
    );

    test(
      '2 & 4. Switching from Account A to Account B clears previous session and binds Account B cleanly',
      () async {
        fakePlatform.onPickAccount = () => const YouTubeAccountSelectionResult(
              status: YouTubeAccountSelectionStatus.selected,
              email: 'account.a@gmail.com',
            );
        final sessionA = await authService.authenticateAndAuthorize();
        expect(sessionA.selectedEmail, equals('account.a@gmail.com'));

        fakePlatform.onPickAccount = () => const YouTubeAccountSelectionResult(
              status: YouTubeAccountSelectionStatus.selected,
              email: 'account.b@gmail.com',
            );
        final sessionB = await authService.authenticateAndAuthorize(
          switchAccount: true,
        );

        expect(fakePlatform.clearCallCount, equals(1));
        expect(fakePlatform.clearedAccountEmail, equals('account.a@gmail.com'));
        expect(sessionB.isAuthorized, isTrue);
        expect(sessionB.selectedEmail, equals('account.b@gmail.com'));
        expect(
          sessionB.accessToken,
          equals('ya29.valid_token_for_account.b@gmail.com'),
        );
      },
    );

    test('8. User cancelling account picker returns cancelledAccountSelection',
        () async {
      fakePlatform.onPickAccount = () => const YouTubeAccountSelectionResult(
            status: YouTubeAccountSelectionStatus.cancelled,
          );

      final session = await authService.authenticateAndAuthorize();
      expect(session.isCancelled, isTrue);
      expect(
        session.outcome,
        equals(YouTubeAuthFlowOutcome.cancelledAccountSelection),
      );
    });

    test('9. User denying YouTube OAuth consent returns permissionDenied',
        () async {
      fakePlatform.onAuthorize = (email, scopes) async =>
          YouTubeAuthorizationResult(
            status: YouTubeAuthorizationStatus.denied,
            selectedAccountEmail: email,
            errorCode: 'access_denied',
          );

      final session = await authService.authenticateAndAuthorize();
      expect(session.isAuthorized, isFalse);
      expect(session.outcome, equals(YouTubeAuthFlowOutcome.permissionDenied));
    });

    test('10. Rejects partial consent when required YouTube scopes are missing',
        () async {
      fakePlatform.onAuthorize = (email, scopes) async =>
          YouTubeAuthorizationResult(
            status: YouTubeAuthorizationStatus.authorized,
            selectedAccountEmail: email,
            accessToken: 'ya29.partial_token',
            grantedScopes: const <String>['email', 'profile'],
          );

      final session = await authService.authenticateAndAuthorize();
      expect(session.isAuthorized, isFalse);
      expect(session.outcome, equals(YouTubeAuthFlowOutcome.permissionDenied));
      expect(session.errorCode, equals('insufficient_scopes'));
    });

    test('11. Rejects cross-account mismatch between picker and OAuth consent',
        () async {
      fakePlatform.onPickAccount = () => const YouTubeAccountSelectionResult(
            status: YouTubeAccountSelectionStatus.selected,
            email: 'picked.user@gmail.com',
          );
      fakePlatform.onAuthorize = (_, scopes) async =>
          YouTubeAuthorizationResult(
            status: YouTubeAuthorizationStatus.authorized,
            selectedAccountEmail: 'wrong.user@gmail.com',
            accessToken: 'ya29.wrong_token',
            grantedScopes: scopes,
          );

      final session = await authService.authenticateAndAuthorize();
      expect(session.isAuthorized, isFalse);
      expect(
        session.outcome,
        equals(YouTubeAuthFlowOutcome.accountMismatchError),
      );
    });
  });

  group('YouTube Data API v3 Channel Verification', () {
    test('5. Account with 1 YouTube channel resolves singleChannelFound',
        () async {
      final mockHttp = MockClient((request) async {
        expect(
          request.headers['Authorization'],
          equals('Bearer ya29.single_channel_token'),
        );
        return http.Response(
          jsonEncode({
            'kind': 'youtube#channelListResponse',
            'items': [
              {
                'id': 'UC_PASTEL_CHANNEL_01',
                'snippet': {
                  'title': 'Pastel Official Channel',
                  'customUrl': '@pastelofficial',
                  'thumbnails': {
                    'high': {'url': 'https://yt3.ggpht.com/avatar1.jpg'}
                  }
                },
                'statistics': {'subscriberCount': '1250', 'videoCount': '42'}
              }
            ]
          }),
          200,
        );
      });

      final service = YouTubeChannelService.forTesting(httpClient: mockHttp);
      final result = await service.fetchOwnedChannels(
        accessToken: 'ya29.single_channel_token',
        accountEmail: 'creator@gmail.com',
      );

      expect(result.hasSingleChannel, isTrue);
      expect(result.singleChannel!.id, equals('UC_PASTEL_CHANNEL_01'));
      expect(result.singleChannel!.title, equals('Pastel Official Channel'));
      expect(result.singleChannel!.customUrl, equals('@pastelofficial'));
    });

    test(
      '6. Account with 0 YouTube channels returns noChannelFound and never binds Gmail as channel',
      () async {
        final mockHttp = MockClient((request) async {
          return http.Response(
            jsonEncode({'kind': 'youtube#channelListResponse', 'items': []}),
            200,
          );
        });

        final service = YouTubeChannelService.forTesting(httpClient: mockHttp);
        final result = await service.fetchOwnedChannels(
          accessToken: 'ya29.no_channel_token',
          accountEmail: 'nochannelyet@gmail.com',
        );

        expect(result.hasNoChannels, isTrue);
        expect(result.channels, isEmpty);
        expect(result.errorMessage, contains('nochannelyet@gmail.com'));
      },
    );

    test(
      '7. Account with multiple YouTube channels returns multipleChannelsFound so user picks explicitly',
      () async {
        final mockHttp = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'kind': 'youtube#channelListResponse',
              'items': [
                {
                  'id': 'UC_MAIN_01',
                  'snippet': {'title': 'Main Channel', 'customUrl': '@main'}
                },
                {
                  'id': 'UC_BRAND_02',
                  'snippet': {'title': 'Brand Channel', 'customUrl': '@brand'}
                }
              ]
            }),
            200,
          );
        });

        final service = YouTubeChannelService.forTesting(httpClient: mockHttp);
        final result = await service.fetchOwnedChannels(
          accessToken: 'ya29.multi_channel_token',
          accountEmail: 'multi@gmail.com',
        );

        expect(result.hasMultipleChannels, isTrue);
        expect(result.channels.length, equals(2));
        expect(result.channels[0].id, equals('UC_MAIN_01'));
        expect(result.channels[1].id, equals('UC_BRAND_02'));
      },
    );
  });

  group('YouTube Token Refresh & Strict Backend Sync Validation', () {
    test(
      '12. Refreshes expired token automatically and requires strict connected=true from backend',
      () async {
        final fakePlatform = FakeYouTubeAuthPlatform();
        final mockHttp = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['channel_id'], equals('UC_VERIFIED_99'));
          expect(
            body['access_token'],
            equals('ya29.valid_token_for_expired@gmail.com'),
          );
          return http.Response(
            jsonEncode({
              'status': 'success',
              'connected': true,
              'message': 'تم ربط قناة YouTube بنجاح',
            }),
            200,
          );
        });

        final tokenService = YouTubeTokenService.forTesting(
          httpClient: mockHttp,
          authPlatform: fakePlatform,
        );

        final expiredSession = YouTubeAuthSession(
          outcome: YouTubeAuthFlowOutcome.authorized,
          selectedEmail: 'expired@gmail.com',
          accessToken: 'ya29.old_expired_token',
          grantedScopes: YouTubeAuthService.kRequiredYouTubeScopes,
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        );

        const channel = YouTubeChannelInfo(
          id: 'UC_VERIFIED_99',
          title: 'Verified Studio',
        );

        final syncResult = await tokenService.syncChannelConnection(
          authSession: expiredSession,
          channel: channel,
        );

        expect(syncResult.isConnected, isTrue);
        expect(syncResult.status, equals(YouTubeBackendSyncStatus.connected));
      },
    );

    test(
      '14. Meta Isolation: YouTube navigation interceptor never matches Meta or Facebook URLs',
      () {
        expect(
          YouTubeConnectionCoordinator.isYouTubeConnectNavigation(
            Uri.parse(
              'https://pastel-eg.com/provider/automation-settings/provider/social-connections/meta/connect',
            ),
          ),
          isFalse,
        );
        expect(
          YouTubeConnectionCoordinator.isYouTubeConnectNavigation(
            Uri.parse('https://www.facebook.com/v19.0/dialog/oauth?client_id=1'),
          ),
          isFalse,
        );
        expect(
          YouTubeConnectionCoordinator.isYouTubeConnectNavigation(
            Uri.parse(
              'https://pastel-eg.com/provider/automation-settings/provider/social-connections/youtube/connect',
            ),
          ),
          isTrue,
        );
      },
    );
  });
}
