import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/navigation_service.dart';
import '../../services/youtube/youtube_auth_service.dart';
import '../../services/youtube/youtube_channel_service.dart';
import '../../services/youtube/youtube_token_service.dart';

class YouTubeConnectionCoordinator {
  YouTubeConnectionCoordinator._internal();

  static final YouTubeConnectionCoordinator instance =
      YouTubeConnectionCoordinator._internal();

  WebViewController? _webViewController;
  bool _isDialogOpen = false;

  void attachWebViewController(WebViewController controller) {
    _webViewController = controller;
  }

  static bool isYouTubeConnectNavigation(Uri uri) {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();

    if (host.contains('pastel-eg.com') &&
        path.contains('/social-connections/youtube/connect')) {
      return true;
    }

    if (host.contains('accounts.google.com') &&
        path.contains('/o/oauth2') &&
        (uri.queryParameters['scope']?.contains('youtube') == true ||
            uri.queryParameters['redirect_uri']
                    ?.contains('/social-connections/youtube/callback') ==
                true)) {
      return true;
    }

    return false;
  }

  Future<void> launchYouTubeConnectionFlow() async {
    if (_isDialogOpen) return;
    final context = NavigationService.instance.currentContext;
    if (context == null) return;

    _isDialogOpen = true;
    try {
      final connected = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => YouTubeConnectionScreen(
          webViewController: _webViewController,
        ),
      );

      if (connected == true && _webViewController != null) {
        await _webViewController!.reload();
      }
    } finally {
      _isDialogOpen = false;
    }
  }
}

enum _YouTubeUiStage {
  readyToPickAccount,
  pickingAccount,
  authorizingPermissions,
  fetchingChannels,
  selectingChannel,
  noChannelOnAccount,
  syncingBackend,
  connectedSuccess,
  errorState,
}

class YouTubeConnectionScreen extends StatefulWidget {
  final WebViewController? webViewController;
  final YouTubeAuthService? authService;
  final YouTubeChannelService? channelService;
  final YouTubeTokenService? tokenService;
  final bool autoStartOnOpen;

  const YouTubeConnectionScreen({
    super.key,
    this.webViewController,
    this.authService,
    this.channelService,
    this.tokenService,
    this.autoStartOnOpen = true,
  });

  @override
  State<YouTubeConnectionScreen> createState() =>
      _YouTubeConnectionScreenState();
}

class _YouTubeConnectionScreenState extends State<YouTubeConnectionScreen> {
  YouTubeAuthService get _authService =>
      widget.authService ?? YouTubeAuthService.instance;
  YouTubeChannelService get _channelService =>
      widget.channelService ?? YouTubeChannelService.instance;
  YouTubeTokenService get _tokenService =>
      widget.tokenService ?? YouTubeTokenService.instance;

  _YouTubeUiStage _stage = _YouTubeUiStage.readyToPickAccount;
  YouTubeAuthSession? _authSession;
  List<YouTubeChannelInfo> _availableChannels = const <YouTubeChannelInfo>[];
  YouTubeChannelInfo? _selectedChannel;
  String? _statusMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.autoStartOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startAccountSelectionFlow(switchAccount: false);
      });
    }
  }

  Future<void> _startAccountSelectionFlow({required bool switchAccount}) async {
    if (!mounted) return;
    setState(() {
      _stage = _YouTubeUiStage.pickingAccount;
      _errorMessage = null;
      _statusMessage = 'جاري فتح قائمة حسابات Google المتاحة على الجهاز...';
    });

    debugPrint("[YouTubeOAuthDebug][Flutter-UI] Starting _startAccountSelectionFlow(switchAccount=" + switchAccount.toString() + ")");
    final session = await _authService.authenticateAndAuthorize(
      switchAccount: switchAccount,
      onStepChanged: (step) {
        if (!mounted) return;
        if (step == 'picking_account') {
          setState(() {
            _stage = _YouTubeUiStage.pickingAccount;
            _statusMessage = 'اختر حساب Google الذي تريد ربط قناته...';
          });
        } else if (step == 'authorizing_youtube') {
          setState(() {
            _stage = _YouTubeUiStage.authorizingPermissions;
            _statusMessage = 'يرجى الموافقة على صلاحيات الوصول إلى قناة YouTube...';
          });
        }
      },
    );

    if (!mounted) return;

    debugPrint("[YouTubeOAuthDebug][Flutter-UI] Received YouTubeAuthSession | outcome=" + session.outcome.name + ", isAuthorized=" + session.isAuthorized.toString() + ", isCancelled=" + session.isCancelled.toString() + ", errorCode=" + (session.errorCode ?? "null") + ", errorMessage=" + (session.errorMessage ?? "null"));
    if (session.isCancelled) {
      setState(() {
        _stage = _YouTubeUiStage.readyToPickAccount;
        _errorMessage = session.errorMessage;
        _statusMessage = null;
      });
      return;
    }

    if (!session.isAuthorized) {
      setState(() {
        _stage = _YouTubeUiStage.errorState;
        _authSession = session;
        _errorMessage =
            session.errorMessage ?? 'تعذر إتمام تفويض حساب Google المختار.';
        _statusMessage = null;
      });
      return;
    }

    _authSession = session;
    await _resolveChannelsForSession(session);
  }

  Future<void> _resolveChannelsForSession(YouTubeAuthSession session) async {
    if (!mounted) return;
    setState(() {
      _stage = _YouTubeUiStage.fetchingChannels;
      _errorMessage = null;
      _statusMessage =
          'جاري التحقق من قنوات YouTube المرتبطة بالحساب (${session.selectedEmail})...';
    });

    final resolution = await _channelService.fetchOwnedChannels(
      accessToken: session.accessToken!,
      accountEmail: session.selectedEmail!,
    );

    if (!mounted) return;

    if (resolution.hasNoChannels) {
      setState(() {
        _stage = _YouTubeUiStage.noChannelOnAccount;
        _availableChannels = const <YouTubeChannelInfo>[];
        _selectedChannel = null;
        _errorMessage = resolution.errorMessage;
        _statusMessage = null;
      });
      return;
    }

    if (resolution.hasSingleChannel) {
      final channel = resolution.singleChannel!;
      setState(() {
        _availableChannels = <YouTubeChannelInfo>[channel];
        _selectedChannel = channel;
      });
      await _bindSelectedChannel(channel);
      return;
    }

    if (resolution.hasMultipleChannels) {
      setState(() {
        _stage = _YouTubeUiStage.selectingChannel;
        _availableChannels = resolution.channels;
        _selectedChannel = resolution.channels.first;
        _errorMessage = null;
        _statusMessage =
            'تم العثور على ${resolution.channels.length} قنوات YouTube على هذا الحساب. اختر القناة المراد ربطها:';
      });
      return;
    }

    setState(() {
      _stage = _YouTubeUiStage.errorState;
      _errorMessage =
          resolution.errorMessage ?? 'تعذر التحقق من قنوات YouTube لهذا الحساب.';
      _statusMessage = null;
    });
  }

  Future<void> _bindSelectedChannel(YouTubeChannelInfo channel) async {
    final session = _authSession;
    if (session == null || !session.isAuthorized) return;

    setState(() {
      _stage = _YouTubeUiStage.syncingBackend;
      _errorMessage = null;
      _statusMessage = 'جاري ربط قناة "${channel.title}" مع حسابك في Pastel...';
    });

    final syncResult = await _tokenService.syncChannelConnection(
      authSession: session,
      channel: channel,
      webViewController: widget.webViewController,
    );

    if (!mounted) return;

    if (syncResult.isConnected) {
      setState(() {
        _stage = _YouTubeUiStage.connectedSuccess;
        _statusMessage = syncResult.message;
        _errorMessage = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
      return;
    }

    setState(() {
      _stage = _YouTubeUiStage.errorState;
      _errorMessage = syncResult.message ?? 'فشل حفظ ربط قناة YouTube على الخادم.';
      _statusMessage = null;
    });
  }

  Future<void> _openCreateYouTubeChannelExternal() async {
    final uri = Uri.parse('https://www.youtube.com/create_channel');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const SizedBox(height: 16),
              if (_authSession?.selectedEmail != null) ...[
                _buildSelectedAccountChip(_authSession!.selectedEmail!),
                const SizedBox(height: 12),
              ],
              _buildStageBody(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final isBusy = _stage == _YouTubeUiStage.pickingAccount ||
        _stage == _YouTubeUiStage.authorizingPermissions ||
        _stage == _YouTubeUiStage.fetchingChannels ||
        _stage == _YouTubeUiStage.syncingBackend;

    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFFEE2E2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.play_circle_fill_rounded,
            color: Color(0xFFDC2626),
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ربط قناة YouTube',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              Text(
                'اختر أي حساب Google مسجل على جهازك',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
        if (!isBusy)
          IconButton(
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.close, color: Color(0xFF64748B)),
            tooltip: 'إغلاق',
          ),
      ],
    );
  }

  Widget _buildSelectedAccountChip(String email) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.account_circle_outlined,
            size: 20,
            color: Color(0xFF475569),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              email,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1E293B),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: () => _startAccountSelectionFlow(switchAccount: true),
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: const Text(
              'تبديل الحساب',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStageBody(BuildContext context) {
    switch (_stage) {
      case _YouTubeUiStage.pickingAccount:
      case _YouTubeUiStage.authorizingPermissions:
      case _YouTubeUiStage.fetchingChannels:
      case _YouTubeUiStage.syncingBackend:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFDC2626)),
              const SizedBox(height: 16),
              Text(
                _statusMessage ?? 'جاري المعالجة...',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF334155),
                ),
              ),
            ],
          ),
        );

      case _YouTubeUiStage.connectedSuccess:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF16A34A),
                size: 54,
              ),
              const SizedBox(height: 12),
              Text(
                _statusMessage ?? 'تم ربط قناة YouTube بنجاح!',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF15803D),
                ),
              ),
            ],
          ),
        );

      case _YouTubeUiStage.noChannelOnAccount:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFD97706),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'لا توجد قناة YouTube على هذا الحساب',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage ??
                        'الحساب المختار لا يحتوي على قناة YouTube مفعلة. يمكنك اختيار حساب Google آخر من جهازك أو إنشاء قناة أولاً.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF78350F),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: () => _startAccountSelectionFlow(switchAccount: true),
              icon: const Icon(Icons.switch_account_rounded),
              label: const Text('اختيار حساب Google آخر من الجهاز'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openCreateYouTubeChannelExternal,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('فتح YouTube لإنشاء قناة على هذا الحساب'),
            ),
          ],
        );

      case _YouTubeUiStage.selectingChannel:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_statusMessage != null) ...[
              Text(
                _statusMessage!,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
              const SizedBox(height: 10),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _availableChannels.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final ch = _availableChannels[index];
                  final isSelected = _selectedChannel?.id == ch.id;
                  return InkWell(
                    onTap: () => setState(() => _selectedChannel = ch),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFFEF2F2)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFDC2626)
                              : const Color(0xFFE2E8F0),
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Radio<String>(
                            value: ch.id,
                            groupValue: _selectedChannel?.id,
                            activeColor: const Color(0xFFDC2626),
                            onChanged: (_) =>
                                setState(() => _selectedChannel = ch),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ch.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                if (ch.customUrl != null &&
                                    ch.customUrl!.isNotEmpty)
                                  Text(
                                    ch.customUrl!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: _selectedChannel == null
                  ? null
                  : () => _bindSelectedChannel(_selectedChannel!),
              icon: const Icon(Icons.link_rounded),
              label: const Text('تأكيد ربط القناة المختارة'),
            ),
          ],
        );

      case _YouTubeUiStage.readyToPickAccount:
      case _YouTubeUiStage.errorState:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFDC2626),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF991B1B),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: () => _startAccountSelectionFlow(
                switchAccount: _authSession != null,
              ),
              icon: const Icon(Icons.account_box_rounded),
              label: Text(
                _authSession == null
                    ? 'اختيار حساب Google من الجهاز'
                    : 'اختيار حساب Google آخر أو إعادة المحاولة',
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('إلغاء'),
            ),
          ],
        );
    }
  }
}
