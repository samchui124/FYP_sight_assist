import '../capture/text_read_result.dart';
import '../vision/detection.dart';

/// 一次讀字的結果，連同**為什麼**（或為什麼沒讀）。
class TextSpot {
  const TextSpot({
    required this.text,
    required this.reason,
    required this.ocrMs,
    required this.decodeMs,
  });

  /// 讀到的文字；沒讀到或沒嘗試時為空字串。
  final String text;

  /// 簡短說明，供 logcat／狀態檔事後診斷。
  final String reason;

  final double ocrMs;
  final double decodeMs;

  bool get hasText => text.isNotEmpty;
}

/// 機會式讀字：只在**偵測的空檔**讀，而且同一段文字只回報一次。
///
/// ## 為什麼是「機會式」而不是「持續」或「按鈕」
///
/// 這台機器（Snapdragon 685，無 NNAPI／GPU delegate）跑單一 int8 模型已經
/// **約 5.2 fps、每次推論 187 ms**，而且 `Interpreter` 自己就用了
/// `setNumThreads(4)`——CPU 基本滿載。
///
/// 所以「平行的第二條執行緒」救不了這件事：**執行緒不會讓工作量變少**。
/// 偵測 187 ms 加 OCR 250 ms 若同時跑，就是 437 ms 的算力要在同一顆 CPU 上分，
/// 結果是偵測掉到約 2 fps。那不是並行加速，是把算力切兩半。
///
/// 真正划算的取捨是**減少 OCR 的次數**，並且把它塞進偵測用不到的空隙：
/// 每一幀的推論結束、下一幀還沒到的時候，CPU 是空的。在那裡讀字，
/// **引導不掉幀**——這是安全前提（偵測才是與危險相關的那一半）。
///
/// 代價是招牌慢一拍。接受它。
///
/// ## 三條規則
///
/// 1. **場景沒變就不重讀。** 相機停在同一個畫面時重複 OCR 是純浪費，
///    而「畫面沒變」可以用偵測框的粗略簽章判斷，比再跑一次 OCR 便宜得多。
/// 2. **同一段文字只回報一次。** 否則同一塊招牌每 1.5 秒唸一次。
/// 3. **讀不到字就退避。** 「沒字」是常態（對著馬路、天空），
///    一直試只是白燒 CPU；連續失敗越多次，下一次間隔越長。
///
/// ## 它不決定「要不要出聲」
///
/// 這裡只產生 [TextSpot]。要不要唸、會不會蓋掉障礙物播報，
/// 由 `Announcer` 決定（它才知道自己剛才說了什麼）。
/// 刻意分成兩件事：一個管成本，一個管安全。
class TextSpotter {
  TextSpotter({
    required Future<TextReadResult> Function() read,
    this.minInterval = const Duration(milliseconds: 1500),
    this.maxInterval = const Duration(seconds: 12),
    this.repeatCooldown = const Duration(seconds: 20),
    DateTime Function()? clock,
    // prefer_initializing_formals 建議改成 `required this._read`，
    // 但那會把底線私有名暴露成公開參數標籤，寧可保留顯式賦值。
    // ignore: prefer_initializing_formals
  })  : _read = read,
        _clock = clock ?? DateTime.now;

  final Future<TextReadResult> Function() _read;
  final DateTime Function() _clock;

  /// 兩次嘗試之間的下限間隔。
  final Duration minInterval;

  /// 連續讀不到字時的間隔上限（退避的天花板）。
  final Duration maxInterval;

  /// 同一段文字在這段時間內不重複回報。
  final Duration repeatCooldown;

  DateTime? _lastAttempt;
  DateTime? _lastTextAt;
  DateTime? _lastDeferredAt;
  String _lastText = '';
  String _lastSignature = '';
  String _lastReason = '尚未嘗試';
  int _consecutiveEmpty = 0;
  bool _inFlight = false;

  int get attempts => _attempts;
  int _attempts = 0;

  int get consecutiveEmpty => _consecutiveEmpty;

  /// 最近一次讀字的文字（不論是否已回報過）。供診斷。
  String get lastText => _lastText;

  String get lastReason => _lastReason;

  /// 目前是否正在讀。呼叫方據此避免重入。
  bool get isReading => _inFlight;

  /// 現在的退避間隔（隨連續失敗成長）。
  Duration get currentInterval {
    if (_consecutiveEmpty == 0) return minInterval;
    // 指數退避，但夾在 maxInterval 之下。
    final ms = minInterval.inMilliseconds * (1 << _consecutiveEmpty.clamp(0, 6));
    return Duration(milliseconds: ms.clamp(
      minInterval.inMilliseconds,
      maxInterval.inMilliseconds,
    ));
  }

  /// 由每一幀的偵測結果驅動。**這是唯一的排程入口。**
  ///
  /// 回傳非 null 表示「這次該讀了」——呼叫方應立刻 `await` [tick]。
  /// 刻意不在這裡直接做非同步工作：`onFrame` 由相機回呼呼叫，
  /// 在那裡 await 會拖住下一幀。
  bool shouldReadNow(List<Detection> detections, {DateTime? now}) {
    final at = now ?? _clock();

    if (_inFlight) return _block('上一次還在讀');

    final last = _lastAttempt;
    if (last != null && at.difference(last) < currentInterval) {
      return _block('間隔未到');
    }

    final sig = signatureOf(detections);
    if (sig == _lastSignature) return _block('場景未變');

    _lastReason = '可以讀';
    return true;
  }

  /// 若 [shouldReadNow] 說可以，就真的去讀。
  ///
  /// 回傳 null 表示這次沒有進行讀取（時機不對、或已有一次在跑）。
  Future<TextSpot?> tick(
    List<Detection> detections, {
    DateTime? now,
  }) async {
    final at = now ?? _clock();
    if (!shouldReadNow(detections, now: at)) return null;

    _inFlight = true;
    _lastAttempt = at;
    _attempts++;
    _lastSignature = signatureOf(detections);

    TextReadResult result;
    try {
      result = await _read();
    } catch (e) {
      // 讀取本身拋例外代表原生側壞了。這不是常態，所以**不**計入退避
      // （退避是給「沒字」用的），但必須留下原因。
      _inFlight = false;
      _lastReason = '讀取失敗：$e';
      return TextSpot(
        text: '',
        reason: _lastReason,
        ocrMs: 0,
        decodeMs: 0,
      );
    } finally {
      _inFlight = false;
    }

    if (!result.ok) {
      _lastReason = '原生回報失敗：${result.error ?? "(無說明)"}';
      return TextSpot(
        text: '',
        reason: _lastReason,
        ocrMs: result.ocrMs,
        decodeMs: result.decodeMs,
      );
    }

    final text = normalize(result.text);

    if (text.isEmpty) {
      _consecutiveEmpty++;
      _lastReason = '沒有文字（連續 $_consecutiveEmpty 次）';
      return TextSpot(
        text: '',
        reason: _lastReason,
        ocrMs: result.ocrMs,
        decodeMs: result.decodeMs,
      );
    }

    _consecutiveEmpty = 0;

    // ★ 值不值得唸？碎片 + 噪聲寧可丟掉，也不要唸給使用者聽。
    // 見 [isWorthSpeaking]——真機上出現過 "d0那Mele l)" 這種輸出。
    if (!isWorthSpeaking(text, elementCount: result.elements.length)) {
      _lastReason = '讀到的內容不像文字（可能太遠或太模糊），不播報';
      return TextSpot(
        text: '',
        reason: _lastReason,
        ocrMs: result.ocrMs,
        decodeMs: result.decodeMs,
      );
    }

    // 同一段文字在冷卻內不重複回報。**不動 `_lastTextAt`**——
    // 動了就會變成「每次問都說在冷卻」，於是永遠唸不出來。
    if (text == _lastText) {
      final said = _lastTextAt;
      if (said != null && at.difference(said) < repeatCooldown) {
        _lastReason = '與上次相同（冷卻中）';
        return TextSpot(
          text: '',
          reason: _lastReason,
          ocrMs: result.ocrMs,
          decodeMs: result.decodeMs,
        );
      }
    }

    _lastText = text;
    _lastReason = '讀到文字（${text.length} 字）';
    return TextSpot(
      text: text,
      reason: _lastReason,
      ocrMs: result.ocrMs,
      decodeMs: result.decodeMs,
    );
  }

  /// 標記「這段文字已經唸出去了」，開始重複冷卻。
  ///
  /// 由播報端在**真的出聲之後**呼叫。刻意與 [tick] 分開：
  /// 讀到字但因為障礙物正在播報而沒唸，不該進入冷卻——
  /// 否則那個招牌就再也不會被念（播報讓位是常有的事）。
  void markSpoken({DateTime? now}) {
    _lastTextAt = now ?? _clock();
  }

  /// 因為播報讓位而延後。下次不重新計時，但也不進入重複冷卻。
  ///
  /// ## ★ 同時要清掉退避，否則招牌會被自己的退避鎖死
  ///
  /// 退避（[consecutiveEmpty]）的語意是「這裡沒東西好看，別浪費 CPU」。
  /// 但**讓位代表剛剛明明讀到了字**——只是被障礙物播報擠掉而已。
  ///
  /// 若不清掉，會出現一個死結：
  ///
  /// 1. 前幾次真的讀不到字 → 間隔退避到 12 秒
  /// 2. 後來讀到了字，但每次都撞上讓位 → 文字被丟掉
  /// 3. 退避沒被清掉，於是每次都要等 12 秒才重試
  /// 4. 重試時偏好的畫面往往又沒變 → 「場景未變」再擋一次
  ///
  /// 結果是那塊招牌**永遠唸不出來**，而所有計數看起來都「正常」。
  /// 真機上實際觀察到的狀態就是 `spotIntervalMs: 12000` + `場景未變`，
  /// 而 OCR 明明一直在讀到字。
  void defer({DateTime? now}) {
    _lastDeferredAt = now ?? _clock();
    _deferrals++;
    // 讀到字就證明「這裡有東西好看」，退避的前提不成立。
    _consecutiveEmpty = 0;
  }

  DateTime? get lastDeferredAt => _lastDeferredAt;

  /// 因為讓位而丟掉文字的次數。供診斷——它是「讀到字卻沒出聲」的直接證據。
  int get deferrals => _deferrals;
  int _deferrals = 0;

  /// 清空全部狀態。停止引導、換場景時用。
  ///
  /// 為什麼一定要有：`_lastSignature` 留著的話，重新啟動引導時
  /// 若是同一個畫面，會被判成「場景未變」而**再也不讀字**——
  /// 看起來像 OCR 壞了，其實是上一個場景的殘留。
  void reset() {
    _lastAttempt = null;
    _lastTextAt = null;
    _lastDeferredAt = null;
    _lastText = '';
    _lastSignature = '';
    _lastReason = '尚未嘗試';
    _consecutiveEmpty = 0;
    _attempts = 0;
    _deferrals = 0;
    _inFlight = false;
  }

  bool _block(String reason) {
    _lastReason = reason;
    return false;
  }

  /// 偵測結果的粗略簽章，用來判斷「場景有沒有變」。
  ///
  /// 刻意**不准**：我們要的是「畫面大致還是同一個畫面」，
  /// 分數抖動不該讓它變。所以只用量化後的中心點與類別。
  static String signatureOf(List<Detection> detections) {
    if (detections.isEmpty) return 'empty';
    // 排序讓順序不影響簽章（同一組框換個順序不該算「變了」）。
    final keys = detections
        .map((d) => '${d.id}@${(d.cx * 8).round()},${(d.cy * 8).round()}')
        .toList()
      ..sort();
    final buf = StringBuffer();
    buf.write(keys.length);
    buf.write(':');
    buf.write(keys.join('|'));
    return buf.toString();
  }

  /// 正規化讀到的文字：去頭尾空白、把各種換行與連續空白收成單一空格。
  ///
  /// 為什麼要收：ML Kit 在招牌上常把同一個詞切成多行，直接唸會出現
  /// 不自然的斷句；而多餘空白會讓「同一段文字」的比對失敗，
  /// 於是同一塊招牌被重複唸。
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 一個「完整詞」：**三個以上**的連續拉丁字母，或**兩個以上**的連續漢字。
  ///
  /// 為什麼門檻要這麼高：真機的碎片輸出是 `"d0那Mele l)"` 這種，
  /// 裡面 `"Me"` 剛好是 2 個字母，所以「2 個字母算一個詞」的規則**擋不住它**。
  /// 實測驗證過這一點——那是把門檻從 2 提到 3 的直接原因。
  ///
  /// 這個門檻不會誤殺真實招牌：真實的招牌／菜單／指示牌上，
  /// 幾乎一定有「3 字母以上的英文詞」（`Exit`、`Toilet`、`Centre`）
  /// 或「2 字以上的中文詞」（`出口`、`洗手間`、`麥當勞`）。
  /// 相對地，被丟掉的是 `"A12"`、`"G2"`、`"d0"` 這類編號與碎片——
  /// 它們本來就不該被當成「招牌寫著什麼」唸出來。
  /// ## 這道門檻的**能力邊界**（誠實說明）
  ///
  /// 它擋得掉：純噪聲、純數字、單一字母、以及「中文被切碎」的情況
  /// （`"1樓 1/F"` 這種只要漢字不足兩字就會被丟）。
  ///
  /// 它**擋不掉**：`"d0那Mele l)"` 裡剛好有一段 3 字母以上的拉丁字
  /// （`"Mele"`）。任何純字串啟發式都擋不掉這種——它跟真實單字長得一樣，
  /// 只有字典或語言模型才能分辨，而引入那兩者會帶來新的一批誤判，
  /// 而且讓行為難以解釋。
  ///
  /// 所以**根治要靠取像品質**（解析度／對焦／晃動），
  /// 這道門檻只是最後一道安全網，不是解法。
  static final RegExp _wordish =
      RegExp(r'[A-Za-z]{3,}|[\u3400-\u4DBF\u4E00-\u9FFF]{2,}');

  /// 疑似 OCR 噪聲的字元。
  ///
  /// 不含 `-`、`&`、`/`、`'`、`.`、`(`、`)`——那些在真實招牌上很常見
  /// （`7-Eleven`、`A & B`、`1/F`、`McDonald's`），誤判它們會把正常招牌丟掉。
  static final RegExp _noise = RegExp(r'[|_~^`\\<>{}\[\]@#$%*=+;]');

  /// 「短字母段與數字緊黏」——**這是真機碎片輸出最明顯的特徵**。
  ///
  /// 真機讀到的例子：
  ///   - `"i08eeoaia"`：`i` + `08` + `eeoaia`（數字在字母之後）
  ///   - `"d0那Mele l)"`：`d` + `0`（數字在字母之後）
  ///
  /// 所以**兩種順序都要匹配**。第一版只寫了「數字後接字母」，
  /// 結果 `d0` 完全沒被擋掉，測試才把這件事抓出來。
  ///
  /// 真實文字不會這樣：編號是 `A12`、`B1`（**整個 token 就是**長度 ≤ 2 的
  /// 字母加數字），而真詞與數字相鄰時字母段都是完整單字
  /// （`7-Eleven` 的 `Eleven` 有 6 個字母、`Exit 3` 中間有空格）。
  ///
  /// 判準是「**字母段長度 1–2 且直接貼著數字**」，而不是「含數字就丟」——
  /// 後者會誤殺 `7-Eleven`。
  static final RegExp _digitGluedShortLetters =
      RegExp(r'[0-9][A-Za-z]{1,2}|[A-Za-z]{1,2}[0-9]');

  /// 這段文字值不值得唸？
  ///
  /// ## 為什麼一定要有這道門檻
  ///
  /// 真機上出現過 `"i08eeoaia。.g"`、`"d0那Mele l)"` 這種輸出。
  /// 對全盲使用者，「招牌寫著 i08eeoaia」比**什麼都不說**更糟：
  /// 他會以為自己聽錯，或更糟，照著不存在的資訊行動。
  /// **寧可安靜，也不要唸垃圾。**
  ///
  /// ## 判準
  ///
  /// 1. **完整詞**：3+ 連續拉丁字母，或 2+ 連續漢字。
  /// 2. **噪聲字元**佔比 ≤ 35%。
  /// 3. **不含「短字母段緊黏數字」**（見 [_digitGluedShortLetters]）。
  ///
  /// ## 能力邊界（誠實說明，實測確認）
  ///
  /// 仍擋不掉與真實單字長得一樣的碎片——`"i08eeoaia"` 靠第 3 條擋住了，
  /// 但 `"d0那Mele l)"`（含 `Mele`）、`"ONTO)y(n)"`（含 `ONTO`）擋不掉，
  /// 因為那些片段長度與真實單字無異。
  /// 要分辨它們需要字典或語言模型，而引入那兩者會帶來新一批誤判、
  /// 且讓行為難以解釋。
  ///
  /// **根治要靠取像品質與距離**（太遠就別讀），這只是最後一道安全網。
  static bool isWorthSpeaking(String text, {int elementCount = 0}) {
    final t = text.trim();
    if (t.isEmpty) return false;

    // 1. 完整詞。
    if (!_wordish.hasMatch(t)) return false;

    // 2. 噪聲佔比。
    final noise = _noise.allMatches(t).length;
    if (noise * 100 > t.length * 35) return false;

    // 3. 短字母段緊黏數字 → 判為碎片。
    if (_digitGluedShortLetters.hasMatch(t)) return false;

    return true;
  }

  /// 把文字裁到可唸的長度。超過就截斷並加提示。
  ///
  /// 為什麼要裁：整塊招牌的全文可能上百字，唸完會讓使用者站在原地等，
  /// 而且會蓋掉所有障礙物播報。寧可先給最前面這一段。
  static String clip(String text, {int max = 40}) {
    if (text.length <= max) return text;
    return '${text.substring(0, max)}…';
  }
}
