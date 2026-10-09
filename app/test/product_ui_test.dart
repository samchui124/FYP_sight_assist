import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/ui/demo_page.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/vision_source.dart';

/// 主畫面的產品性質。
///
/// ## 這個測試在防什麼
///
/// 這張畫面曾經是開發用的 demo 面板：資料來源切換（相機／假數據）、
/// 門檻滑條、FPS 與推理耗時、診斷面板、除錯疊字。那些是**開發者需要的**，
/// 不是使用者需要的，而且其中兩項對全盲使用者是**有害的**：
///
/// - 門檻滑條：「0.42」不是他能判斷的東西，調了會怎樣也無從得知；
/// - 唯一的 debug 入口是**長按 4 秒**，而 TalkBack 開著時手勢被攔截——
///   也就是說那條路徑在盲用情境下從來沒有真正可用過。
///
/// 所以「內部工具不得回到主畫面」必須是**機械可查**的，不是靠記得。
/// 這裡用實際渲染出來的文字去比對，而不是讀原始碼。
class _FakeSpeaker implements Speaker {
  final List<String> spoken = <String>[];
  int stops = 0;
  bool initialized = false;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<List<String>> languages() async => const <String>['yue-HK'];

  /// 回傳 null 表示不觸發「語音包不符」那條警告台詞。
  @override
  Future<String?> initialize() async {
    initialized = true;
    return null;
  }
}

/// 一個不碰相機、不碰原生通道的假來源。
class _FakeSource implements VisionSource {
  final StreamController<VisionFrame> _c =
      StreamController<VisionFrame>.broadcast();

  @override
  String get displayName => 'Fake';

  @override
  Size get frameSize => const Size(1280, 720);

  @override
  int get rotationDegrees => 90;

  @override
  double threshold = 0.3;

  int initialized = 0;
  int disposed = 0;

  @override
  Stream<VisionFrame> get frames => _c.stream;

  @override
  Future<VisionSourceStatus> initialize() async {
    initialized++;
    return const VisionSourceStatus(ok: true, message: 'Fake ready');
  }

  @override
  Future<VisionDiagnostics?> diagnostics() async => null;

  @override
  Future<void> dispose() async {
    disposed++;
    await _c.close();
  }

  void emit(List<Detection> detections) {
    if (_c.isClosed) return;
    _c.add(VisionFrame(
      detections: detections,
      inferenceMs: 180,
      frameWidth: 1280,
      frameHeight: 720,
    ));
  }
}

/// 取得畫面的 State，用來呼叫測試專用接縫。
///
/// 型別是 `dynamic` 因為 `_DemoPageState` 是私有的——這是刻意的：
/// 那個接縫只用來設定「採集中」這個狀態，不是要讓測試去摸內部結構。
dynamic stateOf(WidgetTester tester) => tester.state(find.byType(DemoPage));

/// 把畫面渲染出來並收集**所有文字**（含語意標籤）。
Future<String> renderAndCollectText(
  WidgetTester tester, {
  Speaker? speaker,
  VisionSource Function()? sourceFactory,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: DemoPage(speaker: speaker, sourceFactory: sourceFactory),
  ));
  await tester.pumpAndSettle();

  final texts = <String>[
    ...tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''),
    ...tester
        .widgetList<Semantics>(find.byType(Semantics))
        .map((s) => s.properties.label ?? ''),
  ];
  return texts.join('\n');
}

void main() {
  setUp(() {
    // 台詞在測試裡要是可預期的，不受執行測試的機器語言影響。
    AppLocale.current = AppLanguage.zh;
  });

  group('主畫面不得出現內部工具', () {
    testWidgets('★ 沒有假數據、沒有內部數字、沒有門檻滑條', (tester) async {
      final text = await renderAndCollectText(tester, speaker: _FakeSpeaker());

      // 這些字串是「這是開發工具」的證據，一個都不該出現。
      // 每一條都對應一個真的存在過的 UI 元件，不是想像出來的。
      const forbidden = <String>[
        '假數據', '假数据', 'Fake data', // 資料來源切換
        '模擬', 'Mock', // 同上的另一半
        '顯示閾值', 'Display threshold', // 門檻滑條
        'FPS', // 效能面板
        '推理', 'Infer', // 效能面板
        '分析幀', 'Analyzed', // 診斷面板
        '分析錯誤', 'Analyze errors',
        '檢測框', 'Boxes',
        '無效', 'Invalid',
        '留邊', 'Pad', // 自適應除錯疊字
        '分數', 'Score', // 診斷面板
        '來源', 'Source', // 來源名稱顯示
      ];

      for (final f in forbidden) {
        expect(text.contains(f), isFalse,
            reason: '主畫面不該出現內部工具的字樣：「$f」\n實際文字：\n$text');
      }
    });

    testWidgets('★ 沒有門檻滑條這個元件', (tester) async {
      await renderAndCollectText(tester, speaker: _FakeSpeaker());
      expect(find.byType(Slider), findsNothing,
          reason: '門檻滑條對全盲使用者沒有意義，不該回到畫面上');
    });

    testWidgets('★ 沒有資料來源切換這個元件', (tester) async {
      await renderAndCollectText(tester, speaker: _FakeSpeaker());
      expect(find.byType(SegmentedButton<Object>), findsNothing);
    });
  });

  group('主畫面的產品內容', () {
    testWidgets('標題是 App 名稱、且不是互動元素', (tester) async {
      final speaker = _FakeSpeaker();
      await renderAndCollectText(tester, speaker: speaker);

      expect(find.text('領路通'), findsOneWidget);
      // 標題不該佔用一次 TalkBack 焦點——這張畫面只有兩個可操作項。
      final excluded = find.ancestor(
        of: find.text('領路通'),
        matching: find.byType(ExcludeSemantics),
      );
      expect(excluded, findsOneWidget);
    });

    testWidgets('未啟動引導時，主按鈕是「啟動引導」', (tester) async {
      await renderAndCollectText(tester, speaker: _FakeSpeaker());
      expect(find.text('啟動引導'), findsOneWidget);
    });

    testWidgets('未啟動引導時，沒有「結束引導」', (tester) async {
      await renderAndCollectText(tester, speaker: _FakeSpeaker());
      expect(find.text('結束引導'), findsNothing);
    });

    testWidgets('★ 標籤是動作 + 結果，不是狀態', (tester) async {
      await renderAndCollectText(tester, speaker: _FakeSpeaker());

      // 「開啟語音」是動作；「語音：開」是狀態。螢幕閱讀器唸的是
      // 「按下去會發生什麼」，所以必須是動作。
      expect(find.text('關閉語音'), findsOneWidget,
          reason: '語音目前是開的，按鈕該說「按下去會關閉」');
      expect(find.textContaining('語音：'), findsNothing);
    });

    testWidgets('沒有裸 Icon 充當按鈕（每個按鈕都有文字標籤）', (tester) async {
      await renderAndCollectText(tester, speaker: _FakeSpeaker());

      // 專案的驗收清單寫著：圖標按鈕全部要有可唸的標籤。
      // 主畫面只用帶文字的按鈕，所以這裡斷言「沒有 IconButton」——
      // 比逐一檢查 tooltip 更強，也更難意外破壞。
      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('啟動引導之後', () {
    testWidgets('★ 按鈕消失、出現結束引導（一個畫面做輸出）', (tester) async {
      final source = _FakeSource();
      await renderAndCollectText(
        tester,
        speaker: _FakeSpeaker(),
        sourceFactory: () => source,
      );

      expect(source.initialized, 1, reason: '應該真的啟動了來源');
      expect(find.text('啟動引導'), findsNothing,
          reason: '引導中沒有需要按的東西了');
      expect(find.text('結束引導'), findsOneWidget);
      expect(find.textContaining('正在引導'), findsWidgets);
    });

    testWidgets('結束引導會拆掉來源，並回到未啟動狀態', (tester) async {
      final source = _FakeSource();
      await renderAndCollectText(
        tester,
        speaker: _FakeSpeaker(),
        sourceFactory: () => source,
      );

      await tester.tap(find.text('結束引導'));
      await tester.pumpAndSettle();

      expect(find.text('啟動引導'), findsOneWidget);
      expect(find.text('結束引導'), findsNothing);

      // 資源清理是**背景**做的（見 _stopGuidance 的說明：清理的 Future
      // 不保證完成，所以不能讓介面等它）。給它一個 microtask 週期。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(source.disposed, 1);
      expect(find.text('啟動引導'), findsOneWidget);
      expect(find.text('結束引導'), findsNothing);
    });

    testWidgets('★ 啟動時先出聲（按了不能沒反應）', (tester) async {
      final speaker = _FakeSpeaker();
      final source = _FakeSource();
      await renderAndCollectText(
        tester,
        speaker: speaker,
        sourceFactory: () => source,
      );

      // 「正在啟動引導」＋狀態句都要被唸出來。第二句是完整句
      // （「正在引導，前方有障礙物會出聲」），不是單獨的「正在引導」——
      // 使用者需要知道接下來會發生什麼，不只是「開始了」。
      expect(speaker.spoken, contains('正在啟動引導'));
      expect(speaker.spoken.any((s) => s.contains('正在引導')), isTrue,
          reason: '實際唸出：${speaker.spoken}');
    });

    testWidgets('關閉語音會立刻停掉正在說的那句', (tester) async {
      final speaker = _FakeSpeaker();
      await renderAndCollectText(
        tester,
        speaker: speaker,
        sourceFactory: () => _FakeSource(),
      );

      await tester.tap(find.text('關閉語音'));
      await tester.pumpAndSettle();

      expect(speaker.stops, greaterThan(0),
          reason: '按了關閉卻還聽到聲音，使用者會以為按鈕壞了');
      expect(find.text('開啟語音'), findsOneWidget);
    });

    testWidgets('★ 採集按鈕說出自己在留存畫面，不是只寫「開始」', (tester) async {
      await renderAndCollectText(
        tester,
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );

      // 這是唯一會把使用者畫面存下來的功能。標籤必須讓他聽得懂
      // 「這會拍下畫面」，而不是一個中性的「開始」。
      expect(find.text('開始採集'), findsOneWidget);
    });

    testWidgets('採集進行中時標籤與圖示都改變（不只靠顏色）', (tester) async {
      await renderAndCollectText(
        tester,
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );

      // 用接縫直接把狀態設成「採集中」。不按按鈕的理由是
      // `_toggleCapture` 有一道正確的守衛：來源不是原生相機就拒絕，
      // 而測試用的是假來源——按下去永遠走「被拒絕」那條路。
      stateOf(tester).capturingForTest = true;
      await tester.pumpAndSettle();

      expect(find.text('停止採集'), findsOneWidget);
      expect(find.text('開始採集'), findsNothing);
      // 狀態只靠顏色是無效的（全盲看不到、色覺障礙也可能分不出），
      // 所以圖示也要跟著換。
      expect(find.byIcon(Icons.stop_circle), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt), findsNothing);
    });

    testWidgets('結束引導會順帶停止採集（否則會一直唸相機失敗）', (tester) async {
      await renderAndCollectText(
        tester,
        speaker: _FakeSpeaker(),
        sourceFactory: () => _FakeSource(),
      );

      stateOf(tester).capturingForTest = true;
      await tester.pumpAndSettle();
      expect(find.text('停止採集'), findsOneWidget);

      await tester.tap(find.text('結束引導'));
      await tester.pumpAndSettle();

      // 回到未啟動狀態後，採集按鈕整排都不在了（那兩個動作沒有相機時
      // 只會回一句「請先啟動引導」）。
      expect(find.text('停止採集'), findsNothing);
      expect(find.text('開始採集'), findsNothing);
      expect(find.text('啟動引導'), findsOneWidget);
    });
  });
}
