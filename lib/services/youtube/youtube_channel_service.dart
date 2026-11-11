import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

@immutable
class YouTubeChannelInfo {
  final String id;
  final String title;
  final String description;
  final String? customUrl;
  final String? thumbnailUrl;
  final String? subscriberCount;
  final String? videoCount;
  final String? uploadsPlaylistId;

  const YouTubeChannelInfo({
    required this.id,
    required this.title,
    this.description = '',
    this.customUrl,
    this.thumbnailUrl,
    this.subscriberCount,
    this.videoCount,
    this.uploadsPlaylistId,
  });

  factory YouTubeChannelInfo.fromGoogleApiItem(Map<String, dynamic> item) {
    final id = (item['id'] as String? ?? '').trim();
    final snippet = item['snippet'] is Map<String, dynamic>
        ? item['snippet'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final statistics = item['statistics'] is Map<String, dynamic>
        ? item['statistics'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final contentDetails = item['contentDetails'] is Map<String, dynamic>
        ? item['contentDetails'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final relatedPlaylists = contentDetails['relatedPlaylists']
            is Map<String, dynamic>
        ? contentDetails['relatedPlaylists'] as Map<String, dynamic>
        : const <String, dynamic>{};

    String? thumbnailUrl;
    final thumbnails = snippet['thumbnails'];
    if (thumbnails is Map<String, dynamic>) {
      for (final key in const ['high', 'medium', 'default']) {
        final entry = thumbnails[key];
        if (entry is Map<String, dynamic> && entry['url'] is String) {
          final url = (entry['url'] as String).trim();
          if (url.isNotEmpty) {
            thumbnailUrl = url;
            break;
          }
        }
      }
    }

    return YouTubeChannelInfo(
      id: id,
      title: (snippet['title'] as String? ?? '').trim(),
      description: (snippet['description'] as String? ?? '').trim(),
      customUrl: (snippet['customUrl'] as String?)?.trim(),
      thumbnailUrl: thumbnailUrl,
      subscriberCount: statistics['subscriberCount']?.toString(),
      videoCount: statistics['videoCount']?.toString(),
      uploadsPlaylistId:
          (relatedPlaylists['uploads'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'description': description,
        'customUrl': customUrl,
        'thumbnailUrl': thumbnailUrl,
        'subscriberCount': subscriberCount,
        'videoCount': videoCount,
        'uploadsPlaylistId': uploadsPlaylistId,
      };
}

enum YouTubeChannelResolutionStatus {
  singleChannelFound,
  multipleChannelsFound,
  noChannelFound,
  unauthorizedToken,
  insufficientPermissions,
  networkOrApiError,
}

@immutable
class YouTubeChannelResolutionResult {
  final YouTubeChannelResolutionStatus status;
  final String accountEmail;
  final List<YouTubeChannelInfo> channels;
  final String? errorCode;
  final String? errorMessage;

  const YouTubeChannelResolutionResult({
    required this.status,
    required this.accountEmail,
    this.channels = const <YouTubeChannelInfo>[],
    this.errorCode,
    this.errorMessage,
  });

  bool get hasSingleChannel =>
      status == YouTubeChannelResolutionStatus.singleChannelFound &&
      channels.length == 1;

  bool get hasMultipleChannels =>
      status == YouTubeChannelResolutionStatus.multipleChannelsFound &&
      channels.length > 1;

  bool get hasNoChannels =>
      status == YouTubeChannelResolutionStatus.noChannelFound;

  YouTubeChannelInfo? get singleChannel =>
      channels.length == 1 ? channels.first : null;
}

class YouTubeChannelService {
  YouTubeChannelService._internal({http.Client? httpClient})
      : _httpClient = httpClient;

  static final YouTubeChannelService instance =
      YouTubeChannelService._internal();

  @visibleForTesting
  factory YouTubeChannelService.forTesting({required http.Client httpClient}) {
    return YouTubeChannelService._internal(httpClient: httpClient);
  }

  final http.Client? _httpClient;

  static const String _kYouTubeChannelsEndpoint =
      'https://www.googleapis.com/youtube/v3/channels'
      '?part=snippet,contentDetails,statistics&mine=true&maxResults=50';

  Future<YouTubeChannelResolutionResult> fetchOwnedChannels({
    required String accessToken,
    required String accountEmail,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final trimmedToken = accessToken.trim();
    final trimmedEmail = accountEmail.trim();

    if (trimmedToken.isEmpty) {
      return YouTubeChannelResolutionResult(
        status: YouTubeChannelResolutionStatus.unauthorizedToken,
        accountEmail: trimmedEmail,
        errorCode: 'empty_access_token',
        errorMessage: 'رمز الوصول إلى YouTube غير صالح أو مفقود.',
      );
    }

    final client = _httpClient ?? http.Client();
    final shouldCloseClient = _httpClient == null;

    try {
      final response = await client
          .get(
            Uri.parse(_kYouTubeChannelsEndpoint),
            headers: <String, String>{
              'Authorization': 'Bearer $trimmedToken',
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return YouTubeChannelResolutionResult(
            status: YouTubeChannelResolutionStatus.networkOrApiError,
            accountEmail: trimmedEmail,
            errorCode: 'invalid_json_structure',
            errorMessage: 'استجابة غير متوقعة من خادم YouTube Data API.',
          );
        }

        final rawItems = decoded['items'];
        final List<YouTubeChannelInfo> parsedChannels = <YouTubeChannelInfo>[];
        if (rawItems is List) {
          for (final item in rawItems) {
            if (item is Map<String, dynamic>) {
              final channel = YouTubeChannelInfo.fromGoogleApiItem(item);
              if (channel.id.isNotEmpty) {
                parsedChannels.add(channel);
              }
            }
          }
        }

        if (parsedChannels.isEmpty) {
          return YouTubeChannelResolutionResult(
            status: YouTubeChannelResolutionStatus.noChannelFound,
            accountEmail: trimmedEmail,
            errorCode: 'no_youtube_channel',
            errorMessage:
                'لا توجد قناة YouTube مفعّلة مرتبطة بحساب Google المختار ($trimmedEmail). '
                'يرجى إنشاء قناة على YouTube أولاً أو اختيار حساب Google آخر يملك قناة.',
          );
        }

        if (parsedChannels.length == 1) {
          return YouTubeChannelResolutionResult(
            status: YouTubeChannelResolutionStatus.singleChannelFound,
            accountEmail: trimmedEmail,
            channels: parsedChannels,
          );
        }

        return YouTubeChannelResolutionResult(
          status: YouTubeChannelResolutionStatus.multipleChannelsFound,
          accountEmail: trimmedEmail,
          channels: parsedChannels,
        );
      }

      String? apiReason;
      String? apiMessage;
      try {
        final dynamic errJson = jsonDecode(response.body);
        if (errJson is Map<String, dynamic> &&
            errJson['error'] is Map<String, dynamic>) {
          final errObj = errJson['error'] as Map<String, dynamic>;
          apiMessage = errObj['message'] as String?;
          final errorsList = errObj['errors'];
          if (errorsList is List &&
              errorsList.isNotEmpty &&
              errorsList.first is Map<String, dynamic>) {
            apiReason =
                (errorsList.first as Map<String, dynamic>)['reason'] as String?;
          }
        }
      } catch (_) {}

      if (response.statusCode == 404 ||
          apiReason == 'channelNotFound' ||
          apiReason == 'youtubeSignupRequired') {
        return YouTubeChannelResolutionResult(
          status: YouTubeChannelResolutionStatus.noChannelFound,
          accountEmail: trimmedEmail,
          errorCode: apiReason ?? 'no_youtube_channel',
          errorMessage:
              'لا توجد قناة YouTube مفعّلة مرتبطة بحساب Google المختار ($trimmedEmail). '
              'يرجى إنشاء قناة على YouTube أولاً أو اختيار حساب Google آخر.',
        );
      }

      if (response.statusCode == 401) {
        return YouTubeChannelResolutionResult(
          status: YouTubeChannelResolutionStatus.unauthorizedToken,
          accountEmail: trimmedEmail,
          errorCode: apiReason ?? 'unauthorized_token',
          errorMessage:
              'انتهت صلاحية جلسة تفويض YouTube أو تم إلغاؤها. يرجى إعادة تفويض الحساب.',
        );
      }

      if (response.statusCode == 403) {
        return YouTubeChannelResolutionResult(
          status: YouTubeChannelResolutionStatus.insufficientPermissions,
          accountEmail: trimmedEmail,
          errorCode: apiReason ?? 'insufficient_permissions',
          errorMessage: apiMessage ??
              'لم يتم منح الصلاحيات الكافية لقراءة بيانات قناة YouTube. يرجى الموافقة على جميع الصلاحيات المطلوبة.',
        );
      }

      return YouTubeChannelResolutionResult(
        status: YouTubeChannelResolutionStatus.networkOrApiError,
        accountEmail: trimmedEmail,
        errorCode: 'youtube_api_http_${response.statusCode}',
        errorMessage: apiMessage ??
            'تعذر التحقق من قناة YouTube عبر YouTube Data API (رمز الحالة: ${response.statusCode}).',
      );
    } on TimeoutException {
      return YouTubeChannelResolutionResult(
        status: YouTubeChannelResolutionStatus.networkOrApiError,
        accountEmail: trimmedEmail,
        errorCode: 'network_timeout',
        errorMessage:
            'انتهت مهلة الاتصال بخدمة YouTube. يرجى التحقق من اتصال الإنترنت والمحاولة مرة أخرى.',
      );
    } catch (e) {
      return YouTubeChannelResolutionResult(
        status: YouTubeChannelResolutionStatus.networkOrApiError,
        accountEmail: trimmedEmail,
        errorCode: 'network_error',
        errorMessage:
            'حدث خطأ في الشبكة أثناء التحقق من قناة YouTube. يرجى المحاولة مرة أخرى.',
      );
    } finally {
      if (shouldCloseClient) {
        client.close();
      }
    }
  }
}
