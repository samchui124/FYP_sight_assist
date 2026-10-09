import 'dart:ui' show Rect;

/// 把原生的数字（可能是 int 或 double）转成 double；不可用时返回 null。
///
/// 放在顶层而不是类里：Kotlin 侧 Double 过通道后 Dart 拿到的是 double，
/// 但 `int` 也可能出现（例如 0 被序列化成整数），两个类都要用同一个转换。
double? _asDouble(Object? v) {
  if (v is double) return v.isFinite ? v : null;
  if (v is int) return v.toDouble();
  return null;
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite) return v.round();
  return 0;
}

/// 一个辨识出来的文字元素（字或词）及其位置。
///
/// 与 `Detection` 的关键区别：**Detection 是归一化坐标，本类不是。**
/// OCR 的坐标是**像素**，原点在转正之后的左上角，参考系是
/// [TextReadResult.width] × [TextReadResult.height]。
///
/// 两者混用不会抛异常，只会把框画到屏幕外，所以命名上刻意分开
/// （`rect` 而不是 `cx/cy/w/h`）。
class TextElement {
  const TextElement({
    required this.text,
    this.rect,
    this.confidence = 0,
  });

  final String text;

  /// 文字的外接矩形（像素）。原生没给 boundingBox 时为 null。
  final Rect? rect;

  /// 置信度。ML Kit 在某些 options 下不填，故预设 0 而非 null——
  /// 0 与「低信心」在显示上没有差别，而 null 会逼每个使用点都判空。
  final double confidence;

  /// 从原生回包的单个元素 Map 解析。
  ///
  /// **防御式**：键缺失、类型不符都退化为 null / 预设值，绝不抛异常。
  /// 契约见 `platform_contract.dart` 的 `VisionKeys.elements`。
  ///
  /// 返回 null 表示「这一项不可用」（没有 text），由 [TextReadResult.fromMap]
  /// 过滤掉——单个坏元素不该丢掉整帧结果。
  static TextElement? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.isEmpty) return null;

    Rect? rect;
    final b = raw['bounds'];
    if (b is Map) {
      final left = _asDouble(b['left']);
      final top = _asDouble(b['top']);
      final right = _asDouble(b['right']);
      final bottom = _asDouble(b['bottom']);
      if (left != null && top != null && right != null && bottom != null) {
        // 空矩形或反向矩形当作没有位置——照原样存会让后面的映射算出负宽高。
        if (right > left && bottom > top) {
          rect = Rect.fromLTRB(left, top, right, bottom);
        }
      }
    }

    return TextElement(
      text: text,
      rect: rect,
      confidence: _asDouble(raw['confidence']) ?? 0,
    );
  }
}

/// 一次「读招牌」的结果。
///
/// 为什么连同耗时一起带回来：这个 spike 唯一真正要回答的问题是
/// **这台手机能不能一边跑检测一边读字**，而那只能用真机数字回答，
/// 不能推估（本项目吃过一次亏：18 类模型在桌面没差别，真机 +10.7%）。
class TextReadResult {
  const TextReadResult({
    required this.ok,
    this.text = '',
    this.lines = const <String>[],
    this.elements = const <TextElement>[],
    this.width = 0,
    this.height = 0,
    this.decodeMs = 0,
    this.ocrMs = 0,
    this.totalMs = 0,
    this.error,
  });

  final bool ok;

  /// 整帧文字，行间以换行连接。这是要**播报**的东西。
  final String text;

  /// 逐行文字（畫面上的每一行）。
  ///
  /// 為什麼要單獨留著而不是只在 [text] 裡用換行表示：
  /// Dart 側要用**行邊界**來斷句——每一行是一個獨立的發聲單元，
  /// 唸完自然停頓。直接拆字串也行，但原生側已經算好了，何必再拆一次。
  final List<String> lines;

  /// 逐元素结果，用于画框与「哪几个字在哪」。
  final List<TextElement> elements;

  /// OCR 所用图像的像素尺寸（转正之后）。[TextElement.rect] 的参考系。
  final int width;
  final int height;

  /// YUV→JPEG→Bitmap 的自建转换耗时。这一段是**我们自己的**开销。
  final double decodeMs;

  /// ML Kit 辨识本身的耗时。
  final double ocrMs;

  final double totalMs;
  final String? error;

  /// 辨识成功但一个字都没有。这是**正常结果**，不是错误——
  /// 对着白墙按下「读招牌」本来就该得到这个。
  ///
  /// 把它与 [ok] == false（真的出错）分开，是为了让上层能播报
  /// 「没有看到文字」而不是「读取失败」——对盲人使用者，
  /// 这两句话的意思完全不同。
  bool get isEmpty => ok && text.trim().isEmpty;

  factory TextReadResult.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) {
      return const TextReadResult(ok: false, error: 'empty reply');
    }

    final rawElements = raw['elements'];
    final elements = rawElements is List
        ? rawElements
            .map(TextElement.fromMap)
            .whereType<TextElement>()
            .toList(growable: false)
        : const <TextElement>[];

    final rawText = raw['text'];
    final rawError = raw['error'];
    final rawLines = raw['lines'];

    return TextReadResult(
      ok: raw['ok'] == true,
      text: rawText is String ? rawText : '',
      lines: rawLines is List
          ? rawLines.whereType<String>().toList(growable: false)
          : const <String>[],
      elements: elements,
      width: _asInt(raw['width']),
      height: _asInt(raw['height']),
      decodeMs: _asDouble(raw['decodeMs']) ?? 0,
      ocrMs: _asDouble(raw['ocrMs']) ?? 0,
      totalMs: _asDouble(raw['totalMs']) ?? 0,
      error: rawError is String ? rawError : null,
    );
  }

  static TextReadResult fail(String message) =>
      TextReadResult(ok: false, error: message);
}
