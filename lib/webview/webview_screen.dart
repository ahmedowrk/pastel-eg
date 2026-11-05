import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/navigation_service.dart';
import '../utils/constants.dart';
import 'webview_controller.dart';

/// The single screen of the app: a full-screen WebView pointed at the
/// Laravel site, with pull-to-refresh, a progress bar, offline/error
/// handling, and automatic navigation when a push notification is tapped.
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final AppWebViewController _appController;

  double _progress = 0;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();

    // If a notification was tapped before this screen existed (cold start
    // from terminated state), NavigationService already captured the URL —
    // use it as the initial URL instead of the default site.
    final initialUrl =
        NavigationService.instance.pendingUrl ?? AppConstants.defaultWebsiteUrl;

    _appController = AppWebViewController(
      initialUrl: initialUrl,
      onProgressChanged: (progress) {
        if (!mounted) return;
        setState(() => _progress = progress / 100);
      },
      onPageStarted: () {
        if (!mounted) return;
        setState(() {
          _isLoading = true;
          _hasError = false;
        });
      },
      onPageFinished: () {
        if (!mounted) return;
        setState(() => _isLoading = false);
      },
      onWebResourceError: (error) {
        if (!mounted) return;
        // Only surface fatal, main-frame errors as a full error screen —
        // resource-level errors (e.g. a missing favicon) are ignored.
        if (error.isForMainFrame ?? true) {
          setState(() {
            _hasError = true;
            _isLoading = false;
            _errorMessage = error.description;
          });
        }
      },
    );

    // Listen for future notification taps while this screen is alive
    // (foreground taps and background-tap-to-resume both land here).
    NavigationService.instance.targetUrlNotifier.addListener(_onTargetUrlChanged);
  }

  void _onTargetUrlChanged() {
    final url = NavigationService.instance.targetUrlNotifier.value;
    if (url != null) {
      _appController.loadUrl(url);
    }
  }

  Future<void> _onRefresh() async {
    await _appController.reload();
  }

  Future<bool> _onWillPop() async {
    if (await _appController.canGoBack()) {
      await _appController.goBack();
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    NavigationService.instance.targetUrlNotifier.removeListener(_onTargetUrlChanged);
    _appController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          navigator.maybePop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (_hasError)
                _buildErrorView()
              else
                RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: WebViewWidget(controller: _appController.controller),
                ),
              if (_isLoading && !_hasError)
                LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return ListView(
      // ListView (not Column) so RefreshIndicator-style pull-to-refresh
      // gestures still work even on the error screen.
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'Unable to load the page',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() => _hasError = false);
                      _appController.reload();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
