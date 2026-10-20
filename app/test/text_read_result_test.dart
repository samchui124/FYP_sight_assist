import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/capture/text_read_result.dart';

/// OCR 回包的解析测试。
///
/// 为什么这些测试值得写：原生是另一个语言写的，回包少一个键、类型不对
/// **不会抛异常**，只会静默变成 null。而 OCR 的失败模式特别隐蔽——
/// 座标系错了框会画到屏幕外，`ok` 判错了会把「没看到字」讲成「读取失败」，
/// 两者使用者都只会觉得「它坏了」，我们却拿不到任何线索。
///
/// 这里逐项固定契约（键名见 `platform_contract.dart` 的 `VisionKeys`）。
void main() {
  group('TextReadResult.fromMap', () {
    test('空回包退化为失败而不是抛异常', () {
      final r = TextReadResult.fromMap(null);
      expect(r.ok, isFalse);
      expect(r.error, 'empty reply');
      expect(r.elements, isEmpty);
      expect(r.isEmpty, isFalse, reason: 'ok=false 时不该被当成「没看到字」');
    });

    test('完整回包解析出文字、元素坐标与各段耗时', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': true,
        'text': '麥當勞\n出口',
        'elements': <Object?>[
          <Object?, Object?>{
            'text': '麥當勞',
            'bounds': <Object?, Object?>{
              'left': 12,
              'top': 30,
              'right': 112,
              'bottom': 60,
            },
            'confidence': 0.91,
          },
        ],
        'decodeMs': 41.5,
        'ocrMs': 180.25,
        'totalMs': 225,
        'width': 640,
        'height': 480,
      });

      expect(r.ok, isTrue);
      expect(r.text, '麥當勞\n出口');
      expect(r.width, 640);
      expect(r.height, 480);
      expect(r.decodeMs, 41.5);
      expect(r.ocrMs, 180.25);
      expect(r.totalMs, 225);
      expect(r.error, isNull);
      expect(r.elements, hasLength(1));

      final el = r.elements.single;
      expect(el.text, '麥當勞');
      expect(el.confidence, closeTo(0.91, 1e-9));
      expect(el.rect, isNotNull);
      expect(el.rect!.left, 12);
      expect(el.rect!.top, 30);
      expect(el.rect!.width, 100);
      expect(el.rect!.height, 30);
    });

    test('辨识成功但没有文字是 isEmpty，不是错误', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': true,
        'text': '   ',
        'elements': <Object?>[],
        'width': 640,
        'height': 480,
      });

      expect(r.ok, isTrue, reason: '对着白墙读不到字，不是失败');
      expect(r.isEmpty, isTrue);
      expect(r.error, isNull);
    });

    test('单个坏元素被丢掉，其余元素仍然保留', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': true,
        'text': 'A',
        'elements': <Object?>[
          <Object?, Object?>{'text': 'A'}, // 没有 bounds：可以接受
          <Object?, Object?>{'bounds': <Object?, Object?>{}}, // 没有 text：丢掉
          'not a map', // 类型不符：丢掉
          <Object?, Object?>{'text': ''}, // 空字串：丢掉
        ],
        'width': 100,
        'height': 100,
      });

      expect(r.elements, hasLength(1));
      expect(r.elements.single.text, 'A');
      expect(r.elements.single.rect, isNull, reason: '缺 bounds 时 rect 为 null 而不是零矩形');
    });

    test('反向／空矩形当作没有位置（避免映射出负宽高）', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': true,
        'text': 'B',
        'elements': <Object?>[
          <Object?, Object?>{
            'text': 'B',
            'bounds': <Object?, Object?>{
              'left': 100,
              'top': 100,
              'right': 50, // right < left
              'bottom': 50,
            },
          },
        ],
      });

      expect(r.elements.single.rect, isNull);
    });

    test('缺键或类型不符时用默认值，不抛异常', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': true,
        // 刻意不提供 text / elements / width / height / 各耗时
      });

      expect(r.ok, isTrue);
      expect(r.text, '');
      expect(r.elements, isEmpty);
      expect(r.width, 0);
      expect(r.height, 0);
      expect(r.decodeMs, 0);
      expect(r.ocrMs, 0);
      expect(r.totalMs, 0);
    });

    test('整数型别的耗时也能接受（Kotlin 侧 0.0 可能序列化成 int）', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': true,
        'text': 'C',
        'decodeMs': 0,
        'ocrMs': 180,
        'width': 640,
        'height': 480,
      });

      expect(r.decodeMs, 0);
      expect(r.ocrMs, 180);
    });

    test('error 只在是字串时才采用', () {
      final r = TextReadResult.fromMap(<Object?, Object?>{
        'ok': false,
        'error': 42, // 型别不对
      });

      expect(r.ok, isFalse);
      expect(r.error, isNull, reason: '非字串的 error 不该被硬转成字串');
    });

    test('fail() 产生可播报的失败结果', () {
      final r = TextReadResult.fail('MissingPluginException');
      expect(r.ok, isFalse);
      expect(r.error, 'MissingPluginException');
      expect(r.isEmpty, isFalse);
    });
  });
}
