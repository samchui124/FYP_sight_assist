/// 登入頁與帳號頁。
///
/// 版面與互動規範見 `docs/A11Y-LOGIN-VISUAL-DESIGN.md`。實作上有四件事
/// 是刻意的，改動前請先讀那份文件：
///
/// ## 1. ★ App 必須能單獨完整運作（設計文件第 9.0 節）
///
/// **關掉 TalkBack，這一頁仍然是完整的產品。**
/// 每一種狀態變化都有 App 自己的 TTS 播報，不依賴螢幕閱讀器。
/// TalkBack 開著時我們退讓（改用 `liveRegion`），因為兩邊都出聲會疊在一起。
/// 見 [_announce] 的分流。
///
/// ## 2. 即時播報與畫面文字是兩份不同的文字
///
/// 播報短（≤ 12 字）、畫面長。TalkBack 唸完一句需要時間，播報太長會在
/// 使用者滑到下一項時被截斷，而他不會知道有東西沒聽到。
///
/// ## 3. 防誤觸靠三件事，不靠「把按鈕做大」
///
/// 對全盲使用者，TalkBack 的「單指移動焦點、雙擊才啟動」本身已是最好的
/// 防誤觸機制。真正的風險是重複觸發與意圖相鄰，所以：
/// [`_busy`] 守衛 + 忙碌時停用按鈕（`onPressed: null`）+ 破壞性動作不相鄰。
///
/// ## 4. 用 `ListView` 而不是 `Column`
///
/// 200% 字級下內容會超出手機高度。`Column` 會直接 overflow，
/// `ListView` 讓它可以捲動。這是排版在最大字級下仍然可用的原因。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_service.dart';
import '../auth/auth_strings.dart';
import '../tts/announcer.dart';

/// 版面尺寸與圓角。**圓角只有三種**（設計文件第 2 節的一致性鎖）。
abstract final class AuthMetrics {
  static const double pagePadding = 24;
  static const double fieldGap = 16;
  static const double sectionGap = 24;

  /// 破壞性動作之前的間隔，刻意比其他間隔大。
  static const double destructiveGap = 40;

  /// 觸控目標最小高度。Android 最低是 48，這裡刻意加大。
  static const double minTargetHeight = 56;

  /// 圓角：按鈕全藥丸、輸入框 12、卡片 16。
  static const Radius inputRadius = Radius.circular(12);
  static const Radius cardRadius = Radius.circular(16);
  static const BorderRadius inputBorder = BorderRadius.all(inputRadius);
  static const BorderRadius cardBorder = BorderRadius.all(cardRadius);
}

/// 觸覺回饋。抽成參數是為了讓測試能斷言「有沒有震」。
typedef HapticCallback = Future<void> Function();

Future<void> _defaultHaptic() => HapticFeedback.lightImpact();

class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    required this.service,
    this.speaker,
    this.onSkip,
    this.onSignedIn,
    this.onBackToGuidance,
    this.haptic,
  });

  final AuthService service;

  /// App 自己的語音。**TalkBack 開著時不會用到它**（見 [_announce]）。
  final Speaker? speaker;

  /// 「稍後再說」。未提供時該按鈕不顯示。
  final VoidCallback? onSkip;

  /// 登入成功時呼叫。宿主通常會在這裡 `Navigator.pop` 回到引導。
  ///
  /// ★ 這個 callback 是「登入完卻卡在帳號頁」的修法。
  /// 使用者的目的是登入以便上傳，不是來逛帳號頁的。
  final void Function(AuthAccount account)? onSignedIn;

  /// 帳號頁的「回到引導」。
  ///
  /// 即使宿主沒有提供 [onSignedIn]，這個按鈕也**一定**會顯示，
  /// 因為「進去出不來」比「沒有自動返回」嚴重得多。
  final VoidCallback? onBackToGuidance;

  final HapticCallback? haptic;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  Set<AuthProvider> _available = const {};
  AuthAccount? _account;

  /// 首次查詢「能用哪些登入方式」還沒回來。
  ///
  /// 這段期間畫面**不能是空的**：空白畫面沒有聲音就等於沒有回饋，
  /// 使用者會以為程式壞了。所以這一期間仍然顯示標題、說明與一句載入提示。
  bool _bootstrapping = true;

  /// ★ 防重複觸發的守衛。停用按鈕是主要防線，這個是補第二層。
  bool _busy = false;

  bool _emailExpanded = false;
  bool _codeSent = false;

  String _statusLong = '';

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // 進入頁面的播報要等第一帧之後，因為需要 MediaQuery。
    WidgetsBinding.instance.addPostFrameCallback((_) => _announceEntry());
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final available = await widget.service.availableProviders();
    final account = await widget.service.restore();
    if (!mounted) return;
    setState(() {
      _available = available;
      _account = account;
      _bootstrapping = false;
    });
  }

  // ---------------------------------------------------------------- 回饋

  /// 螢幕閱讀器是否開著。
  ///
  /// ⚠️ 這一條尚未在真機驗證過：`accessibleNavigation` 是否準確反映
  /// TalkBack 狀態，要開／關各測一次。見設計文件第 10 節。
  bool get _screenReaderOn => MediaQuery.of(context).accessibleNavigation;

  /// 狀態播報的分流。
  ///
  /// - 螢幕閱讀器開著：**不發聲**。狀態區是 `liveRegion`，由它播。
  ///   兩邊都出聲會疊在一起，比只有一邊更糟。
  /// - 螢幕閱讀器關著：用 App 自己的 TTS。
  ///   **這條路徑必須完整**，否則沒開 TalkBack 的使用者就沒有任何回饋。
  void _announce(String short) {
    if (_screenReaderOn) return;
    final speaker = widget.speaker;
    if (speaker == null) return;
    speaker.speak(short).ignore();
  }

  /// 觸覺回饋。同樣分流：TalkBack 自己會給，我們不重複給。
  ///
  /// 為什麼要有觸覺：語音要等 TTS 排隊，**觸覺是立即的**。
  /// 「按到了」這三個字用震動回答比用語音快。
  Future<void> _haptic() async {
    if (_screenReaderOn) return;
    await (widget.haptic ?? _defaultHaptic)();
  }

  void _announceEntry() {
    if (!mounted) return;
    _announce(AuthStrings.current.announceEntry);
  }

  /// 設定狀態。`short` 是**只給耳朵**的那一句，不會顯示在畫面上，
  /// 所以不需要存起來（見設計文件 9.5：播報與畫面文字是兩份不同的文字）。
  void _setStatus(String short, String long) {
    setState(() => _statusLong = long);
    _announce(short);
  }

  // ---------------------------------------------------------------- 動作

  Future<void> _run(Future<AuthResult> Function() op) async {
    if (_busy) return;
    await _haptic();
    // ★ 播報要在**等待網路之前**發生。盲人按下按鈕後的第一個疑問是
    //   「按到了嗎」，不能等伺服器回應才回答他。
    _setStatus(AuthStrings.current.announceSigningIn,
        AuthStrings.current.signingIn);
    setState(() => _busy = true);

    final result = await op();
    if (!mounted) return;
    setState(() => _busy = false);

    final s = AuthStrings.current;
    switch (result) {
      case SignedIn(:final account):
        setState(() => _account = account);
        _setStatus(s.announceSignedIn, s.signedIn);
        // 讓宿主有機會直接回到引導，而不是把使用者留在帳號頁。
        widget.onSignedIn?.call(account);
      case AuthCancelled():
        // ★ 取消不是錯誤。文案裡沒有「失敗」兩個字。
        _setStatus(s.announceCancelled, s.cancelled);
      case AuthFailed(:final problem):
        final (short, long) = switch (problem) {
          AuthProblem.network => (s.announceNetworkError, s.networkError),
          AuthProblem.providerUnavailable => (s.announceNoBiometric, s.noBiometric),
          AuthProblem.accountLocked => (s.announceLocked, s.locked),
          AuthProblem.lastSignInMethod => (s.announceLastMethod, s.lastMethod),
          AuthProblem.rejected || AuthProblem.unknown =>
            (s.announceGenericError, s.genericError),
        };
        _setStatus(short, long);
      case NeedsLinking(:final email, :final existing):
        _setStatus(s.announceNeedsLinking, s.announceNeedsLinking);
        await _confirmLinking(email, existing);
    }
  }

  Future<void> _confirmLinking(String email, AuthProvider existing) async {
    final s = AuthStrings.current;
    final link = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 對話框標題用 header，讓螢幕閱讀器能跳到它（設計文件 9.6）。
        title: Semantics(header: true, child: Text(s.linkingTitle)),
        content: Text(s.linkingBody(existing.displayName)),
        actions: [
          // ★ 焦點順序：安全選項在前（設計文件 1.1）。
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.linkingKeep),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.linkingConfirm),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (link == true) {
      await _run(() => widget.service.linkProvider(existing));
    }
  }

  // ---------------------------------------------------------------- 版面

  @override
  Widget build(BuildContext context) {
    final s = AuthStrings.current;
    // ListView 而不是 Column：200% 字級下 Column 會 overflow。
    return Scaffold(
      body: SafeArea(
        child: FocusTraversalGroup(
          // OrdinalSortKey 讓朗讀順序等於視覺順序，而且重構不會弄壞它。
          policy: OrderedTraversalPolicy(),
          child: ListView(
            padding: const EdgeInsets.all(AuthMetrics.pagePadding),
            children: _account == null ? _loginChildren(s) : _accountChildren(s),
          ),
        ),
      ),
    );
  }

  /// 焦點順序 / 朗讀順序的序號。**這裡是唯一的順序宣告處。**
  Widget _at(int order, Widget child) => FocusTraversalOrder(
        order: NumericFocusOrder(order.toDouble()),
        child: child,
      );

  Widget _heading(String text) => Semantics(
        header: true,
        child: Text(text, style: Theme.of(context).textTheme.headlineSmall),
      );

  Widget _gap(double h) => SizedBox(height: h);

  /// 一顆登入方式按鈕。填色的是主動作，外框的是次要。
  Widget _providerButton(AuthProvider p, int order) {
    final s = AuthStrings.current;
    final label = switch (p) {
      AuthProvider.passkey => s.signInWithPasskey,
      AuthProvider.google => s.signInWithGoogle,
      AuthProvider.apple => s.signInWithApple,
      AuthProvider.emailCode => s.useEmail,
    };
    return _at(
      order,
      Padding(
        padding: const EdgeInsets.only(bottom: AuthMetrics.fieldGap),
        child: FilledButton(
          // 忙碌時 onPressed 為 null -> Flutter 自動帶上 enabled: false，
          // 螢幕閱讀器會唸「已停用」。這是「防重複」與「告訴使用者正在跑」
          // 兩件事的接點（設計文件 9.2）。
          onPressed: _busy ? null : () => _run(() => widget.service.signIn(p)),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
            shape: const StadiumBorder(),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  List<Widget> _loginChildren(AuthStrings s) {
    var order = 1;
    final children = <Widget>[
      _at(order++, _heading(s.title)),
      _gap(AuthMetrics.fieldGap),
      _at(order++, Text(s.intro)),
      _gap(AuthMetrics.sectionGap),
    ];

    // 只顯示**可用**的方式。手機沒設指紋時不顯示指紋按鈕，而不是
    // 顯示了再失敗（設計文件與 stub 設計的 availableProviders 一節）。
    for (final p in const [
      AuthProvider.passkey,
      AuthProvider.google,
      AuthProvider.apple,
    ]) {
      if (_available.contains(p)) children.add(_providerButton(p, order++));
    }

    if (_available.contains(AuthProvider.emailCode)) {
      children.add(_at(
        order++,
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _emailExpanded = !_emailExpanded),
          style: TextButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
          ),
          child: Text(s.useEmail),
        ),
      ));
      if (_emailExpanded) {
        children.addAll(_emailChildren(s, order));
        order += 3;
      }
    }

    if (widget.onSkip != null) {
      children.add(_gap(AuthMetrics.sectionGap));
      children.add(_at(
        order++,
        OutlinedButton(
          onPressed: _busy ? null : widget.onSkip,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
            shape: const StadiumBorder(),
          ),
          child: Text(s.notNow),
        ),
      ));
    }

    children.add(_gap(AuthMetrics.fieldGap));
    children.add(_statusRegion(s));
    return children;
  }

  List<Widget> _emailChildren(AuthStrings s, int order) {
    // ★ 不給 autofocus：鍵盤突然彈出並改掉焦點，對盲人使用者很困惑。
    // ★ textInputAction 不設 submit：打字時誤按 Enter 不該送出登入。
    // ★ label 常駐（floatingLabelBehavior.always）：不留只有 placeholder 的欄位。
    final emailField = TextField(
      controller: _emailController,
      enabled: !_busy,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.email],
      decoration: InputDecoration(
        border: const OutlineInputBorder(borderRadius: AuthMetrics.inputBorder),
        labelText: s.emailLabel,
        floatingLabelBehavior: FloatingLabelBehavior.always,
      ),
    );

    return [
      _gap(AuthMetrics.fieldGap),
      _at(order, emailField),
      _at(
        order + 1,
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                    final r = await widget.service
                        .requestEmailCode(_emailController.text.trim());
                    if (r is SignedIn) setState(() => _codeSent = true);
                    return r;
                  }),
          style: TextButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
          ),
          child: Text(s.sendCode),
        ),
      ),
      if (_codeSent)
        _at(
          order + 2,
          TextField(
            controller: _codeController,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              border:
                  const OutlineInputBorder(borderRadius: AuthMetrics.inputBorder),
              labelText: s.codeLabel,
              helperText: s.codeHint,
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
          ),
        ),
    ];
  }

  List<Widget> _accountChildren(AuthStrings s) {
    final account = _account!;
    return [
      _at(1, _heading(s.accountTitle)),
      _gap(AuthMetrics.fieldGap),
      _at(2, Text(account.email)),
      _at(
        3,
        Text('${s.linkedMethods}: '
            '${account.providers.map(s.providerName).join(', ')}'),
      ),
      _gap(AuthMetrics.sectionGap),
      // ★ 主要動作是「回到引導」，不是「登出」。
      //   使用者是為了上傳才登入的，登入完就該回去，不該停在這裡。
      _at(
        4,
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  _haptic();
                  widget.onBackToGuidance?.call();
                },
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
            shape: const StadiumBorder(),
          ),
          child: Text(s.backToGuidance),
        ),
      ),
      _gap(AuthMetrics.fieldGap),
      _at(
        5,
        OutlinedButton(
          onPressed: _busy
              ? null
              : () async {
                  await _haptic();
                  await widget.service.signOut();
                  if (!mounted) return;
                  setState(() => _account = null);
                  _setStatus(s.announceSignedOut, s.announceSignedOut);
                },
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
            shape: const StadiumBorder(),
          ),
          child: Text(s.signOut),
        ),
      ),
      // ★ 破壞性動作：刻意的大間隔 + 不是填色按鈕（文字色改用 error）。
      _gap(AuthMetrics.destructiveGap),
      _at(
        6,
        TextButton(
          onPressed: _busy ? null : () => _confirmDelete(account),
          style: TextButton.styleFrom(
            minimumSize: const Size.fromHeight(AuthMetrics.minTargetHeight),
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(s.deleteAccount),
        ),
      ),
      _gap(AuthMetrics.fieldGap),
      _statusRegion(s),
    ];
  }

  Future<void> _confirmDelete(AuthAccount account) async {
    final s = AuthStrings.current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Semantics(header: true, child: Text(s.deleteTitle)),
        content: Text(s.deleteBody),
        actions: [
          // ★ 安全選項在焦點順序的第一位。用物件命名而不是「取消」。
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.deleteKeep),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.deleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.service.deleteAccount();
    if (!mounted) return;
    setState(() => _account = null);
  }

  /// 狀態區。
  ///
  /// `liveRegion: true` 讓狀態變化**主動播出且不移動焦點**。
  /// TalkBack 關著時這行沒有作用，改用我們自己的 TTS（見 [_announce]），
  /// 所以兩條路徑都是完整的。
  Widget _statusRegion(AuthStrings s) {
    // 載入期間借這個區域顯示提示：畫面不留白，也就永遠有回饋。
    final text = _bootstrapping ? s.loading : _statusLong;
    if (text.isEmpty) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
