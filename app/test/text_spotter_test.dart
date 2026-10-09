import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/capture/text_read_result.dart';
import 'package:pathguide/text/text_spotter.dart';
import 'package:pathguide/vision/detection.dart';

/// 機會式讀字的排程邏輯。
///
/// ## 為什麼這些測試值得寫
///
/// 這裡的每一條規則都是**成本**與**安全**的取捨，而它們在真機上完全無法驗證：
/// 你不可能一邊舉著手機一邊數「剛才那塊招牌該不該重唸」。
/// 而且失敗模式特別隱蔽——讀太勤會讓引導掉幀（看不出是誰害的），
/// 重複冷卻寫錯會讓招牌**永遠唸不出來**（看起來像 OCR 壞了）。
///
/// 所以時鐘可注入，把取捨全釘死。
class _Clock {
  DateTime now = DateTime(2026, 10, 9, 12, 0, 0);
  void advance(Duration d) => now = now.add(d);
  DateTime call() => now;
}

Detection _det(int id, {double cx = 0.5, double cy = 0.5}) => Detection(
      id: id,
      score: 0.9,
      cx: cx,
      cy: cy,
      w: 0.2,
      h: 0.2,
    );

TextReadResult _ok(String text, {double ocrMs = 200, double decodeMs = 60}) =>
    TextReadResult(
      ok: true,
      text: text,
      ocrMs: ocrMs,
      decodeMs: decodeMs,
      width: 640,
      height: 480,
    );

void main() {
  late _Clock clock;
  late int readCalls;
  late TextReadResult Function() nextResult;

  TextSpotter make({
    Duration minInterval = const Duration(milliseconds: 1500),
    Duration repeatCooldown = const Duration(seconds: 20),
  }) =>
      TextSpotter(
        read: () async {
          readCalls++;
          return nextResult();
        },
        minInterval: minInterval,
        repeatCooldown: repeatCooldown,
        clock: clock.call,
      );

  setUp(() {
    clock = _Clock();
    readCalls = 0;
    nextResult = () => _ok('麥當勞');
  });

  group('機會式排程', () {
    test('第一次就讀，並回報文字', () async {
      final s = make();
      final spot = await s.tick(<Detection>[_det(7)]);

      expect(spot, isNotNull);
      expect(spot!.hasText, isTrue);
      expect(spot.text, '麥當勞');
      expect(readCalls, 1);
      expect(spot.ocrMs, 200);
      expect(spot.decodeMs, 60);
    });

    test('間隔未到時不讀（這是保護引導幀率的核心）', () async {
      final s = make(minInterval: const Duration(seconds: 2));
      await s.tick(<Detection>[_det(7)]);

      // 場景變了、但時間還沒到。
      clock.advance(const Duration(milliseconds: 500));
      final second = await s.tick(<Detection>[_det(7, cx: 0.9)]);

      expect(second, isNull, reason: '間隔未到就不該再讀一次');
      expect(readCalls, 1);
    });

    test('場景沒變就不重讀（相機停住時不空燒 CPU）', () async {
      final s = make(minInterval: const Duration(milliseconds: 100));
      await s.tick(<Detection>[_det(7)]);

      clock.advance(const Duration(seconds: 5));
      final second = await s.tick(<Detection>[_det(7)]);

      expect(second, isNull);
      expect(readCalls, 1, reason: '畫面一樣，重讀純屬浪費');
    });

    test('分數抖動不算場景改變，但位置改變算', () async {
      final s = make(minInterval: const Duration(milliseconds: 100));
      await s.tick(<Detection>[_det(7)]);

      clock.advance(const Duration(seconds: 1));
      // 位置只動一滴滴（同一個量化格）→ 視為沒變。
      final tiny = await s.tick(<Detection>[_det(7, cx: 0.501)]);
      expect(tiny, isNull);
    });

    test('順序不同但同一組框，不視為場景改變', () {
      final a = TextSpotter.signatureOf(<Detection>[_det(1), _det(2)]);
      final b = TextSpotter.signatureOf(<Detection>[_det(2), _det(1)]);
      expect(a, b);
    });

    test('偵測為空也算一種場景，可以讀', () async {
      final s = make();
      final spot = await s.tick(const <Detection>[]);
      expect(spot, isNotNull);
      expect(readCalls, 1);
    });
  });

  group('去重', () {
    test('同一段文字在冷卻內不重複回報', () async {
      final s = make(minInterval: const Duration(milliseconds: 100));
      final first = await s.tick(<Detection>[_det(7)]);
      expect(first!.text, '麥當勞');
      // 唸出去之後才進入重複冷卻（見「沒有 markSpoken 就不進冷卻」那條）。
      s.markSpoken();

      clock.advance(const Duration(seconds: 1));
      final second = await s.tick(<Detection>[_det(7, cx: 0.9)]);

      expect(second!.hasText, isFalse);
      expect(second.reason, contains('相同'));
      expect(readCalls, 2, reason: '還是會讀，只是不回報');
    });

    test('markSpoken 之後才進入重複冷卻', () async {
      final s = make(
        minInterval: const Duration(milliseconds: 100),
        repeatCooldown: const Duration(seconds: 10),
      );
      await s.tick(<Detection>[_det(7)]);
      s.markSpoken();

      clock.advance(const Duration(seconds: 2));
      final second = await s.tick(<Detection>[_det(7, cx: 0.9)]);
      expect(second!.hasText, isFalse, reason: '剛唸過，冷卻中');
    });

    test('★ 冷卻過後同一段文字仍可再唸（不會永久靜音）', () async {
      final s = make(
        minInterval: const Duration(milliseconds: 100),
        repeatCooldown: const Duration(seconds: 10),
      );
      await s.tick(<Detection>[_det(7)]);
      s.markSpoken();

      // 冷卻內：不報。
      clock.advance(const Duration(seconds: 2));
      expect((await s.tick(<Detection>[_det(7, cx: 0.9)]))!.hasText, isFalse);

      // 冷卻過後：要能再報。**這條是防止「招牌永遠唸不出來」的關鍵。**
      clock.advance(const Duration(seconds: 20));
      final again = await s.tick(<Detection>[_det(7, cx: 0.3)]);
      expect(again!.hasText, isTrue);
      expect(again.text, '麥當勞');
    });

    test('★ 沒有 markSpoken 就不進冷卻（讓位後仍可再試）', () async {
      final s = make(minInterval: const Duration(milliseconds: 100));
      final first = await s.tick(<Detection>[_det(7)]);
      expect(first!.hasText, isTrue);

      // 刻意不呼叫 markSpoken：代表「讀到了但因為障礙物播報而沒唸」。
      clock.advance(const Duration(seconds: 2));
      final second = await s.tick(<Detection>[_det(7, cx: 0.9)]);

      expect(second!.hasText, isTrue,
          reason: '沒唸出去就不該進冷卻，否則那個招牌再也不會被念');
    });

    test('文字正規化：換行與連續空白收成單一空格', () {
      expect(TextSpotter.normalize('麥當勞\n  出口   '), '麥當勞 出口');
      expect(TextSpotter.normalize('   '), '');
    });

    test('換行差異不會被當成不同文字', () async {
      final s = make(minInterval: const Duration(milliseconds: 100));
      await s.tick(<Detection>[_det(7)]);
      s.markSpoken();

      nextResult = () => _ok('麥當勞\n');
      clock.advance(const Duration(seconds: 1));
      final second = await s.tick(<Detection>[_det(7, cx: 0.9)]);

      expect(second!.hasText, isFalse, reason: '正規化後是同一段文字');
    });
  });

  group('退避', () {
    test('讀不到字會拉長間隔', () async {
      final s = make(minInterval: const Duration(seconds: 2));
      nextResult = () => _ok('');

      await s.tick(<Detection>[_det(7)]);
      expect(s.consecutiveEmpty, 1);
      expect(s.currentInterval, greaterThan(const Duration(seconds: 2)));

      // 退避是**累積**的（1.5s → 3s → 6s…），所以要推得夠遠。
      // 只推 3 秒會被第二次的間隔擋住，測試會誤判成「退避沒生效」。
      clock.advance(const Duration(seconds: 30));
      await s.tick(<Detection>[_det(7, cx: 0.9)]);
      expect(s.consecutiveEmpty, 2);
    });

    test('退避有上限，不會無限成長', () async {
      final s = make(minInterval: const Duration(seconds: 2));
      nextResult = () => _ok('');

      for (var i = 0; i < 12; i++) {
        clock.advance(const Duration(seconds: 30));
        // 每次都要讓**場景簽章**不同，否則會被「場景未變」擋掉，
        // 量到的就不是退避行為了。簽章把 cx 量化成 8 格，所以用 /8。
        await s.tick(<Detection>[_det(7, cx: i / 8.0)]);
      }

      expect(s.currentInterval, lessThanOrEqualTo(s.maxInterval));
      expect(s.consecutiveEmpty, 12);
    });

    test('讀到文字就把退避清掉', () async {
      final s = make(minInterval: const Duration(milliseconds: 100));
      nextResult = () => _ok('');
      await s.tick(<Detection>[_det(7)]);
      expect(s.consecutiveEmpty, 1);

      nextResult = () => _ok('出口');
      clock.advance(const Duration(seconds: 30));
      final spot = await s.tick(<Detection>[_det(7, cx: 0.9)]);

      expect(spot!.hasText, isTrue);
      expect(s.consecutiveEmpty, 0);
      expect(s.currentInterval, s.minInterval);
    });
  });

  group('錯誤處理', () {
    test('原生回報失敗時不當成「沒字」，且不計入退避', () async {
      final s = make();
      nextResult = () => TextReadResult.fail('boom');

      final spot = await s.tick(<Detection>[_det(7)]);

      expect(spot!.hasText, isFalse);
      expect(spot.reason, contains('boom'));
      expect(s.consecutiveEmpty, 0,
          reason: '原生壞掉與「畫面沒字」是兩件事，不該混進同一個退避計數');
    });

    test('read 拋例外不會讓呼叫方炸掉', () async {
      final s = TextSpotter(
        read: () async => throw StateError('原生通道斷了'),
        clock: clock.call,
      );

      final spot = await s.tick(<Detection>[_det(7)]);

      expect(spot, isNotNull);
      expect(spot!.hasText, isFalse);
      expect(spot.reason, contains('讀取失敗'));
    });

    test('非 ok 但仍帶部分耗時時，耗時要傳出來（供診斷）', () async {
      final s = make();
      nextResult = () => TextReadResult(
            ok: false,
            error: '逾時',
            decodeMs: 55,
          );

      final spot = await s.tick(<Detection>[_det(7)]);
      expect(spot!.decodeMs, 55);
    });
  });

  group('裁切', () {
    test('短文字不裁', () {
      expect(TextSpotter.clip('麥當勞', max: 40), '麥當勞');
    });

    test('長文字裁到上限並加省略號', () {
      final long = '字' * 100;
      final clipped = TextSpotter.clip(long, max: 40);
      expect(clipped.length, 41, reason: '40 個字 + 省略號');
      expect(clipped.endsWith('…'), isTrue);
    });
  });
}
