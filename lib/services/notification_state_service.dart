import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

class NotificationStateService with WidgetsBindingObserver {
  NotificationStateService._internal() {
    WidgetsBinding.instance.addObserver(this);
  }
  static final NotificationStateService instance = NotificationStateService._internal();

  WebViewController? _webViewController;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      syncState();
    }
  }

  void attachWebViewController(WebViewController controller) {
    _webViewController = controller;
  }

  Future<void> syncState() async {
    if (_webViewController == null) return;
    try {
      final jsCode = '''
      (function() {
        function getCsrfToken() {
          var meta = document.querySelector('meta[name="csrf-token"]');
          if (meta && meta.getAttribute('content')) {
            return meta.getAttribute('content');
          }
          var cookies = document.cookie.split(';');
          for (var i = 0; i < cookies.length; i++) {
            var c = cookies[i].trim();
            if (c.indexOf('XSRF-TOKEN=') === 0) {
              return decodeURIComponent(c.substring(11));
            }
          }
          return '';
        }

        var csrfToken = getCsrfToken();

        fetch('/ar/mobile/notifications/state?limit=30', {
          method: 'GET',
          headers: {
            'Accept': 'application/json',
            'X-CSRF-TOKEN': csrfToken,
            'X-Requested-With': 'XMLHttpRequest'
          },
          credentials: 'include'
        })
        .then(function(res) {
          if (res.ok) {
            return res.json().then(function(data) {
              if (window.NotificationStateChannel) {
                window.NotificationStateChannel.postMessage(JSON.stringify({ type: 'sync', status: 'success', data: data }));
              }
            });
          } else {
             if (window.NotificationStateChannel) {
                window.NotificationStateChannel.postMessage(JSON.stringify({ type: 'sync', status: 'error', httpCode: res.status }));
             }
          }
        })
        .catch(function(err) {
            if (window.NotificationStateChannel) {
              window.NotificationStateChannel.postMessage(JSON.stringify({ type: 'sync', status: 'error', error: err.toString() }));
            }
        });
      })();
      ''';
      await _webViewController!.runJavaScript(jsCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationStateService] syncState error: $e');
    }
  }

  Future<void> readNotification(String notificationId) async {
    if (_webViewController == null) return;
    try {
      final jsCode = '''
      (function() {
        function getCsrfToken() {
          var meta = document.querySelector('meta[name="csrf-token"]');
          if (meta && meta.getAttribute('content')) {
            return meta.getAttribute('content');
          }
          var cookies = document.cookie.split(';');
          for (var i = 0; i < cookies.length; i++) {
            var c = cookies[i].trim();
            if (c.indexOf('XSRF-TOKEN=') === 0) {
              return decodeURIComponent(c.substring(11));
            }
          }
          return '';
        }
        
        var csrfToken = getCsrfToken();
        
        fetch('/ar/mobile/notifications/read', {
          method: 'POST',
          headers: {
             'Content-Type': 'application/json',
             'Accept': 'application/json',
             'X-CSRF-TOKEN': csrfToken,
             'X-Requested-With': 'XMLHttpRequest'
          },
          body: JSON.stringify({
            notification_ids: [${jsonEncode(notificationId)}]
          }),
          credentials: 'include'
        })
        .then(function(res) {
          if (res.ok) {
            return res.json().then(function(data) {
              if (window.NotificationStateChannel) {
                window.NotificationStateChannel.postMessage(JSON.stringify({ type: 'read', status: 'success', data: data }));
              }
            });
          }
        })
        .catch(function(err) {
          console.error(err);
        });
      })();
      ''';

      await _webViewController!.runJavaScript(jsCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationStateService] readNotification error: $e');
    }
  }

  Future<void> markAllRead() async {
    if (_webViewController == null) return;
    try {
       final jsCode = '''
      (function() {
        function getCsrfToken() {
          var meta = document.querySelector('meta[name="csrf-token"]');
          if (meta && meta.getAttribute('content')) {
            return meta.getAttribute('content');
          }
          var cookies = document.cookie.split(';');
          for (var i = 0; i < cookies.length; i++) {
            var c = cookies[i].trim();
            if (c.indexOf('XSRF-TOKEN=') === 0) {
              return decodeURIComponent(c.substring(11));
            }
          }
          return '';
        }
        
        var csrfToken = getCsrfToken();
        
        fetch('/ar/mobile/notifications/read', {
          method: 'POST',
          headers: {
             'Content-Type': 'application/json',
             'Accept': 'application/json',
             'X-CSRF-TOKEN': csrfToken,
             'X-Requested-With': 'XMLHttpRequest'
          },
          body: JSON.stringify({
            mark_all: true
          }),
          credentials: 'include'
        })
        .then(function(res) {
          if (res.ok) {
             if (window.NotificationStateChannel) {
                window.NotificationStateChannel.postMessage(JSON.stringify({ type: 'mark_all', status: 'success' }));
             }
          }
        })
        .catch(function(err) {
          console.error(err);
        });
      })();
      ''';

      await _webViewController!.runJavaScript(jsCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationStateService] markAllRead error: $e');
    }
  }

  void handleJavascriptMessage(String message) {
    try {
      final Map<String, dynamic> data = jsonDecode(message);
      final type = data['type'];
      final status = data['status'];

      if (status == 'success') {
        if (type == 'sync' || type == 'read') {
           final badgeVal = data['data']?['badge'];
           if (badgeVal != null) {
              _updateBadge(badgeVal);
           }
        } else if (type == 'mark_all') {
           _updateBadge(0);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationStateService] Error parsing JS message: $e');
    }
  }

  Future<void> updateBadgeFromPush(String badgeStr) async {
    final badgeVal = int.tryParse(badgeStr);
    if (badgeVal != null) {
      _updateBadge(badgeVal);
    }
  }

  Future<void> _updateBadge(dynamic badgeValue) async {
    try {
      int? badge;
      if (badgeValue is int) badge = badgeValue;
      if (badgeValue is String) badge = int.tryParse(badgeValue);

      if (badge == null) return;

      final supported = await AppBadgePlus.isSupported();
      if (!supported) return;

      if (badge > 0) {
        await AppBadgePlus.updateBadge(badge);
      } else {
        await AppBadgePlus.updateBadge(0);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationStateService] _updateBadge error: $e');
    }
  }
}
