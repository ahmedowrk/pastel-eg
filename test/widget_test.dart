import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pastel/services/tiktok_auth_service.dart';
import 'package:pastel/services/tiktok_backend_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.pasteleg.app/tiktok_sdk');

  group('TikTokAuthService Native MethodChannel Contract Tests', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TikTokAuthService.instance.cancel();
    });

    test('returns success when native SDK returns matching state, code, and verifier', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'authorize') {
          final Map<dynamic, dynamic> args = call.arguments as Map<dynamic, dynamic>;
          return <String, dynamic>{
            'status': 'success',
            'code': 'clt.valid_auth_code_12345',
            'codeVerifier': 'aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY',
            'state': args['state'],
            'redirectUri': args['redirectUri'],
            'grantedPermissions': 'user.info.basic',
            'usedNativeApp': true,
          };
        }
        return null;
      });

      final TikTokAuthResult result = await TikTokAuthService.instance.authorize();
      expect(result.isSuccess, isTrue);
      expect(result.code, equals('clt.valid_auth_code_12345'));
      expect(result.codeVerifier, equals('aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY'));
      expect(result.grantedScopes, equals({'user.info.basic'}));
      expect(result.usedNativeApp, isTrue);
    });

    test('rejects response when returned state does not match request state', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'authorize') {
          return <String, dynamic>{
            'status': 'success',
            'code': 'clt.valid_auth_code_12345',
            'codeVerifier': 'aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY',
            'state': 'tampered_state_value',
            'redirectUri': 'https://pastel-eg.com/social-connections/tiktok/callback',
            'grantedPermissions': 'user.info.basic',
            'usedNativeApp': true,
          };
        }
        return null;
      });

      final TikTokAuthResult result = await TikTokAuthService.instance.authorize();
      expect(result.isSuccess, isFalse);
      expect(result.status, equals(TikTokAuthStatus.failed));
    });

    test('does not fabricate grantedScopes when SDK returns empty grantedPermissions', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'authorize') {
          final Map<dynamic, dynamic> args = call.arguments as Map<dynamic, dynamic>;
          return <String, dynamic>{
            'status': 'success',
            'code': 'clt.valid_auth_code_12345',
            'codeVerifier': 'aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY',
            'state': args['state'],
            'redirectUri': args['redirectUri'],
            'grantedPermissions': '',
            'usedNativeApp': false,
          };
        }
        return null;
      });

      final TikTokAuthResult result = await TikTokAuthService.instance.authorize();
      expect(result.isSuccess, isTrue);
      expect(result.grantedScopes, isEmpty);
    });
  });

  group('TikTokBackendService Contract Validation Tests', () {
    test('accepts valid Laravel response with mandatory fields', () {
      final String body = jsonEncode({
        'status': 'success',
        'connection_id': 'tiktok_conn_901',
        'provider': 'tiktok',
        'connected_account': {
          'open_id': '_000tiktok_user_123',
          'display_name': 'Pastel Studio',
          'avatar_url': 'https://example.com/avatar.jpg',
        },
      });

      final TikTokBackendConnectResult res =
          TikTokBackendService.instance.parseSuccessResponse(body);
      expect(res.isSuccess, isTrue);
      expect(res.connectionId, equals('tiktok_conn_901'));
      expect(res.openId, equals('_000tiktok_user_123'));
      expect(res.displayName, equals('Pastel Studio'));
    });

    test('rejects HTTP 200 response missing connection_id without fabricating fake ID', () {
      final String body = jsonEncode({
        'status': 'success',
        'provider': 'tiktok',
        'connected_account': {
          'open_id': '_000tiktok_user_123',
          'display_name': 'Pastel Studio',
        },
      });

      final TikTokBackendConnectResult res =
          TikTokBackendService.instance.parseSuccessResponse(body);
      expect(res.isSuccess, isFalse);
      expect(res.connectionId, isNull);
      expect(res.errorCode, equals('MISSING_MANDATORY_FIELDS'));
    });

    test('maps explicit 422 error codes accurately instead of assuming permission_denied', () {
      final http.Response invalidGrantResp = http.Response(
        jsonEncode({
          'status': 'error',
          'code': 'INVALID_GRANT',
          'message': 'Authorization code expired or verifier mismatch.',
        }),
        422,
      );
      final TikTokBackendConnectResult res1 =
          TikTokBackendService.instance.parseErrorResponse(invalidGrantResp);
      expect(res1.status, equals('authentication_failed'));

      final http.Response missingPermResp = http.Response(
        jsonEncode({
          'status': 'error',
          'code': 'MISSING_PERMISSIONS',
          'message': 'Required TikTok scopes were not granted.',
        }),
        422,
      );
      final TikTokBackendConnectResult res2 =
          TikTokBackendService.instance.parseErrorResponse(missingPermResp);
      expect(res2.status, equals('permission_denied'));
    });
  });
}
