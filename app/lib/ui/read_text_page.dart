import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/text_read_result.dart';
import '../l10n/app_strings.dart';
import '../text/text_spotter.dart';
import '../vision/detection.dart';
import '../vision/vision_preview.dart';
import '../tts/announcer.dart';
import '../vision/vision_session.dart';
import '../vision/vision_source.dart';

/// 讀字模式：**招牌、菜單、指示牌**等任何有文字的東西。
///
/// ## 與引導模式的三個關鍵差別
///
/// | | 引導模式 | 讀字模式（本頁） |
/// |---|---|---|
/// | 障礙物播報 | 開 | **關** |
/// | 讀字節奏 | 機會式（擠偵測空檔） | **固定節奏，讀字優先** |
/// | 讀不到時 | 靜默 | **出聲說明** |
///
/// ### 為什麼這裡要關掉障礙物播報
///
/// 真機實測招牌有**一半**被障礙物播報讓位丟掉（`spotDeferred` 12/22），
/// 而且永遠不會補唸。使用者進到這個模式是**刻意要讀字**，
/// 不是在走路需要前方警示；讓兩者搶語音只會兩邊都做不好。
///
/// 所以這個模式**不建立 Announcer**——沒有東西可以搶。
///
/// ### 為什麼讀不到要出聲
///
/// 原本靜默，結果使用者分不出「畫面裡沒字」與「功能壞了」。
/// 全盲使用者沒有任何視覺線索，只能反覆對準、反覆失望。
/// 說一句「沒有看到文字」就把這個不確定性消掉。
class ReadTextPage extends StatefulWidget {
  const ReadTextPage({
    super.key,
    this.session,
    this.speaker,
    this.sourceFactory,
  });

  /// 相機與語音的共用持有者。正式流程由 `HomePage` 注入。
  ///
  /// 沒注入就自己建一個——測試與未來深層連結都需要這條路。
  final VisionSession? session;

  /// 語音輸出（測試用）。有 [session] 時以 session 的為準。
  final Speaker? speaker;

  /// 建立來源（測試用）。有 [session] 時以 session 的為準。
  final VisionSource Function()? sourceFactory;

  @override
  State<ReadTextPage> createState() => _ReadTextPageState();
}

class _ReadTextPageState extends State<ReadTextPage> {
  late final VisionSession _session = widget.session ??
      VisionSession(
        speaker: widget.speaker,
        sourceFactory: widget.sourceFactory,
      );
  /// 讀字用的排程器。
  ///
  /// 與引導模式**不同參數**：這裡讀字是主要目的，所以間隔短、不因
  /// 場景未變而長期不讀（見 [_onTick]）。
  late final TextSpotter _spotter = TextSpotter(
    read: _readNow,
    minInterval: const Duration(milliseconds: 1200),
    maxInterval: const Duration(seconds: 6),
    repeatCooldown: const Duration(seconds: 6),
  );

  Timer? _timer;
  VisionSourceStatus? _status;
  String _statusText = '';
  bool _busy = false;

  /// 最近一次讀到的文字（顯示用）。
  String _lastText = '';

  /// 目前是不是在讀（顯示用）。
  bool get _reading => _busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final s = AppStrings.current;
    setState(() => _statusText = s.reading);
    // 先出聲再做事——這個專案把「按了之後沒反應」列為最嚴重的缺口。
    _session.say(s.readTextReady);

    final status = await _session.ensureCamera();
    if (!mounted) return;
    setState(() {
      _status = status;
      _statusText = status.ok ? s.readTextReady : status.message;
    });
    if (!status.ok) {
      // 相機起不來**必須出聲**，否則使用者只會一直對準然後失望。
      _session.say(status.message);
      return;
    }

    // 固定節奏，不等偵測結果。
    // 引導模式是「機會式」（擠偵測空檔），但這裡讀字是主要目的，
    // 所以有自己的節拍——這也是分成兩個模式的直接好處。
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _onTick());
  }

  void _onTick() {
    if (!mounted || _busy) return;
    final src = _session.source;
    if (src == null) return;
    // 場景未變也照讀：使用者是**靜止對著招牌**在等它唸，
    // 這時候「不重讀」反而是錯的。（引導模式才需要避開重讀。）
    if (!_spotter.shouldReadNow(const <Detection>[])) return;
    unawaited(_attempt(force: false));
  }

  Future<void> _attempt({required bool force}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final spot = await _spotter.tick(const <Detection>[]);
      if (!mounted) return;
      if (spot == null) return;

      if (!spot.hasText) {
        // ★ 只有「真的沒看到字」才出聲說明；「被讓位」不是使用者的問題。
        _reportEmptyIfSettled(spot);
        return;
      }

      _lastText = spot.text;
      setState(() => _statusText = spot.text);
      _speakChunks(spot.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 連續讀不到時出聲說明——**但要避免每 1.2 秒唸一次「沒有看到文字」**。
  ///
  /// 所以只在「連續失敗達到門檻」時說一次，之後靠 `_emptyAnnouncedTo`
  /// 記住已說過，直到又讀到文字才重設。
  int _emptyStreakWhenAnnounced = -1;
  void _reportEmptyIfSettled(TextSpot spot) {
    if (spot.reason.contains('不像文字')) {
      // 讀到東西但不像文字（碎片/噪聲）。這也是「沒讀到」，
      // 而且更需要說明——否則使用者會以為系統在亂讀。
    }
    if (_spotter.consecutiveEmpty < 3 && !spot.reason.contains('不像文字')) {
      return;
    }
    if (_emptyStreakWhenAnnounced == _spotter.consecutiveEmpty) return;
    _emptyStreakWhenAnnounced = _spotter.consecutiveEmpty;
    _session.say(AppStrings.current.noTextFound);
  }

  /// 逐句唸。第一句加前綴，之後不加（否則每句都重複很吵）。
  void _speakChunks(String text) {
    final chunks = TextSpotter.capTotal(TextSpotter.toChunks(text));
    if (chunks.isEmpty) return;
    // 讀字模式沒有障礙物播報在搶，所以直接排隊即可。
    // 每一句都用自己的話說，讓佇列自然產生停頓。
    final prefix = AppStrings.current.readSignPrefix;
    for (var i = 0; i < chunks.length; i++) {
      _session.say(i == 0 ? '$prefix${chunks[i]}' : chunks[i]);
    }
  }

  /// 「再讀一次」：清掉去重與退避，立刻重讀。
  Future<void> _readAgain() async {
    final s = AppStrings.current;
    _session.say(s.reading);
    _spotter.reset();
    _emptyStreakWhenAnnounced = -1;
    await _session.stopSpeaking();
    if (!mounted) return;
    setState(() => _statusText = s.reading);
    await _attempt(force: true);
  }

  /// 讀一幀文字。
  Future<TextReadResult> _readNow() async {
    final src = _session.platform;
    if (src == null || !src.supportsTextReading) {
      return TextReadResult.fail('此平台或此來源不支援讀字');
    }
    return src.readText();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 不停相機：它由 [VisionSession] 擁有，跨模式存活（避免切模式要等 1–2 秒）。
    // 但**要停語音**——離開讀字模式後不該還在唸上一塊招牌。
    _session.stopSpeaking();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.current;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _header(s),
            Expanded(child: _preview(s)),
            _actions(s),
          ],
        ),
      ),
    );
  }

  Widget _header(AppStrings s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: <Widget>[
          ExcludeSemantics(
            child: Text(
              s.modeReadText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          if (_reading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _preview(AppStrings s) {
    final ok = _status?.ok ?? false;
    if (!ok) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _status == null ? s.reading : _statusText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const VisionPreview(),
        // 讀到的文字疊在畫面上，給低視力使用者與陪護者看。
        if (_lastText.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xCC000000),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _lastText,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
              ),
            ),
          ),
      ],
    );
  }

  Widget _actions(AppStrings s) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              _statusText.isEmpty ? s.reading : _statusText,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _readAgain,
              icon: const Icon(Icons.refresh, size: 24),
              label: Text(
                s.readAgain,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 22),
              label: Text(s.backToHome),
            ),
          ),
        ],
      ),
    );
  }
}
