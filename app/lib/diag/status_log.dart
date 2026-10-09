import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 把診斷資訊寫成**檔案**，而不是畫在畫面上。
///
/// ## 為什麼要有這個（而不是留一個診斷面板）
///
/// 產品畫面只留產品該有的東西，所以那些計數（分析幀數、跳過原因、錯誤行號、
/// FPS、推理耗時）沒有地方顯示了。但**不能因此把它們丟掉**——
/// `VisionPlugin.kt` 裡那段計數器的註解記著它的來歷：
///
/// > 曾出現「預覽正常、但推理 0 次」的情況，而當時**拿不到任何計數**，
/// > 只能靠反覆重新構建來猜。
///
/// 所以改成「寫出來」：`logcat`（`Log.i/w`，原生側已經在寫）加上這個檔案。
/// 真機出問題時，事後把檔案拉出來就能看到，不必連著電腦重現。
///
/// ## 為什麼是**覆寫**而不是**附加**
///
/// 這是本檔案最重要的設計決定，理由是**隱私**：
///
/// 這個 App 拍的是香港街頭。一個會無限增長的檔案，等於在使用者裝置上
/// 累積一份「他走過哪裡、看到什麼」的紀錄——那是這個專案明確不該有的東西
/// （`docs/PROJECT-STATUS.md` 記著雲端上傳是**完成路徑後**由使用者決定的事，
/// 本地更不該默默留紀錄）。
///
/// 所以：**永遠只保留最近一份快照**，覆寫同一個檔案。沒有歷史、沒有輪替
/// 之外的其他檔案。要更多歷史就接 logcat。
///
/// ## 具體做法
///
/// - 寫入用 `tmp` 檔 + `rename`，避免拉到「寫到一半」的檔案
/// - 內容是**當下狀態**，不是事件流（事件流請看 logcat）
/// - 任何 IO 失敗都吞掉：診斷壞掉不該讓引導壞掉
class StatusLog {
  StatusLog({required this.dir, this.interval = const Duration(seconds: 5)});

  /// 應用私有目錄（由原生 `modelDir` 提供）。
  ///
  /// 為什麼要注入而不是自己找：`path_provider` 會拉進 `objective_c`，
  /// 那是本倉庫的硬約束（路徑含空格會讓 build hook 失敗）。
  /// 原生已經有一個可寫目錄，用它。
  final String dir;

  /// 兩次寫檔之間的最小間隔。畫面 5 fps，不能每幀都碰磁碟。
  final Duration interval;

  File? _file;
  DateTime? _lastWrite;
  int _writes = 0;

  /// 寫入次數，供測試斷言「節流真的在起作用」。
  int get writes => _writes;

  String get path => '$_dirPath/status.json';

  String get _dirPath => dir.endsWith('/') || dir.endsWith(r'\')
      ? dir.substring(0, dir.length - 1)
      : dir;

  /// 判斷是否該寫（節流）。抽出來是為了讓測試不必真的等時間過去。
  bool shouldWrite(DateTime now) {
    final last = _lastWrite;
    return last == null || now.difference(last) >= interval;
  }

  /// 寫一份快照。節流由呼叫方用 [shouldWrite] 決定，或直接呼叫 [maybeWrite]。
  Future<void> write(Map<String, Object?> snapshot, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    _lastWrite = at;
    _writes++;

    // 先寫 logcat。**即使寫檔失敗也要有紀錄**，所以順序是「先送出去、再落地」。
    if (kDebugMode) {
      debugPrint('[PathGuide status] ${_compact(snapshot)}');
    }

    try {
      final f = _file ??= File(path);
      final parent = f.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        _encode(snapshot, at),
        flush: true,
      );
      // rename 是原子的（同一檔案系統）。這樣拉檔案的人永遠不會看到
      // 「寫到一半」的 JSON——而不完整的 JSON 會讓事後診斷直接失敗。
      await tmp.rename(f.path);
    } on FileSystemException catch (e) {
      // 刻意吞掉。診斷寫不進去不該讓引導停下；這正是它與播報的差別。
      if (kDebugMode) {
        debugPrint('[PathGuide status] 寫入失敗（已忽略）：$e');
      }
    }
  }

  /// 依節流規則決定是否寫。
  Future<void> maybeWrite(
    Map<String, Object?> Function() snapshot, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    if (!shouldWrite(at)) return;
    await write(snapshot(), now: at);
  }

  /// 一行式的摘要，給 logcat 用（logcat 一行太長會被截斷）。
  static String _compact(Map<String, Object?> m) =>
      m.entries.map((e) => '${e.key}=${e.value}').join(' ');

  /// 手寫 JSON 而不是 `jsonEncode`：這裡的值全是原始型別，
  /// 而手寫可以保證**每個鍵都出現**（缺鍵在事後診斷時最難處理——
  /// 分不清「沒有這件事」與「沒寫進去」）。
  static String _encode(Map<String, Object?> m, DateTime at) {
    final buf = StringBuffer('{\n');
    buf.writeln('  "at": "${at.toIso8601String()}",');
    var first = true;
    for (final e in m.entries) {
      if (!first) buf.writeln(',');
      first = false;
      buf.write('  ${_jsonString(e.key)}: ${_jsonValue(e.value)}');
    }
    buf.write('\n}\n');
    return buf.toString();
  }

  static String _jsonString(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  static String _jsonValue(Object? v) => switch (v) {
        null => 'null',
        final bool b => b ? 'true' : 'false',
        final int i => '$i',
        final double d => d.isFinite ? d.toStringAsFixed(3) : 'null',
        final Map<Object?, Object?> m => '{${m.entries.map(
              (e) => '${_jsonString('${e.key}')}: ${_jsonValue(e.value)}',
            ).join(', ')}}',
        final Iterable<Object?> l =>
          '[${l.map(_jsonValue).join(', ')}]',
        _ => _jsonString('$v'),
      };
}
