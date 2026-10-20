/// **只在真機上量 OCR 用的入口，不是正式入口。**
///
/// ## 為什麼要有這個檔案
///
/// 真機上出現兩個問題，而它們都**無法靠讀程式碼判斷**：
///
/// 1. **讀到亂碼**（例如 `"d0那Mele l)"`）——猜測是取像只有 640×480。
/// 2. **英文被逐字母唸出**——可能是圖太小導致拉丁字被切成單字元，
///    也可能是中文辨識器對拉丁字切詞不好。
///
/// 產品路徑（機會式排程）每 1.5–12 秒才跑一次、還受「場景未變」影響，
/// **根本沒辦法穩定重現**同一張圖。所以改用這個入口：對**固定圖片**
/// 在**不同解析度**下各跑一遍，把結果並排印出來。
///
/// ## 用法
///
/// ```
/// flutter build apk --debug --target=lib/main_ocr_debug.dart
/// adb install -r build/app/outputs/flutter-apk/app-debug.apk
/// adb shell am start -n hk.pathguide.pathguide/.MainActivity
/// adb logcat -s flutter          # 看並排結果
/// ```
///
/// 量完之後把手機裝回正式入口（`flutter build apk --debug`，不帶 `--target`）。
///
/// 它呼叫原生側的 `ocrFile`（見 `VisionPlugin.ocrFileCall`），
/// 那是**診斷專用**通道，產品路徑不會用到。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vision/platform_contract.dart';

/// 要量的圖片檔名。
///
/// **放在 app 私有目錄**，不是 `/sdcard/Download`——後者在 Android 10+
/// 受分區儲存限制，`BitmapFactory.decodeFile` 會直接失敗（實測回
/// 「解碼失敗」）。私有目錄不需要任何權限。
///
/// 放進去的方法：
/// ```
/// adb push sign.png /data/local/tmp/
/// adb shell run-as hk.pathguide.pathguide cp /data/local/tmp/sign.png files/ocrtest/
/// ```
///
/// ## 這份矩陣在測什麼（每一個變因都對應相機路徑上的一個環節）
///
/// | 檔名 | 隔離的變因 |
/// |---|---|
/// | `sign_r1280` / `r0640` / `r0320` | **原始取像解析度** |
/// | `j_q95` / `j_q60` | **JPEG 品質**（相機路徑用 85）|
/// | `j_q85x2` | **二次編碼**（現況：rotateJpegIfNeeded 再壓一次）|
/// | `blur_0.8` / `1.6` / `3.0` | **模糊**（手持晃動、失焦）|
///
/// 為什麼要一次全測：真機上相機讀到的是亂碼，而**猜不到**是解析度、
/// 壓縮、還是模糊造成的。與其逐項猜，不如全部一次印出來對照。
const List<(String, int)> _matrix = <(String, int)>[
  // 基準：全解析度、無額外壓縮、無模糊
  ('sign_r1280.png', 0),
  // 解析度
  ('sign_r0640.png', 0),
  ('sign_r0320.png', 0),
  // JPEG 品質（真 .jpg，quality 才有作用）
  ('q95.jpg', 0),
  ('q60.jpg', 0),
  // 二次 JPEG 編碼 = 相機目前的路徑（rotateJpegIfNeeded 會再壓一次）
  ('q85x2.jpg', 0),
  // 模糊：手持晃動 / 失焦
  ('b08.jpg', 0),
  ('b16.jpg', 0),
  ('b30.jpg', 0),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OcrBenchApp());
}

class _OcrBenchApp extends StatefulWidget {
  const _OcrBenchApp();

  @override
  State<_OcrBenchApp> createState() => _OcrBenchAppState();
}

class _OcrBenchAppState extends State<_OcrBenchApp> {
  final MethodChannel _ch = const MethodChannel(kVisionChannel);
  final List<String> _lines = <String>[];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    // 先畫一幀，確保畫面有東西（否則使用者會以為當掉）。
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // 私有目錄由原生提供（`modelDir` 回的就是 filesDir，不需要 path_provider）。
    String base;
    try {
      base = await _ch.invokeMethod<String>(VisionMethods.modelDir) ?? '';
    } catch (e) {
      _log('取不到私有目錄：$e');
      setState(() => _done = true);
      return;
    }
    if (base.isEmpty) {
      _log('私有目錄是空的，無法繼續');
      setState(() => _done = true);
      return;
    }
    _log('私有目錄 $base');

    for (final (name, maxDim) in _matrix) {
      final path = '$base/ocrtest/$name';
      _log('--- $name @ maxDim=$maxDim ---');
      try {
        final r = await _ch.invokeMethod<Map<Object?, Object?>>(
          'ocrFile',
          <String, Object>{'path': path, 'maxDim': maxDim, 'script': 'zh'},
        );
        if (r == null || r['ok'] != true) {
          _log('  FAILED: ${r?['error']}');
          continue;
        }
        final elems = (r['elementTexts'] as List?)?.cast<Object?>() ?? const [];
        _log('  圖 ${r['width']}x${r['height']}  '
            '${r['elementCount']} 個元素  '
            'ocrMs=${(r['ocrMs'] as num?)?.toStringAsFixed(0)}');
        _log('  elements=$elems');
      } catch (e) {
        _log('  EXCEPTION: $e');
      }
    }
    _log('=== 量測結束 ===');
    setState(() => _done = true);
  }

  void _log(String s) {
    // logcat 是唯一可靠的取用管道（畫面可能沒人看）。
    debugPrint('[OCRBENCH] $s');
    _lines.add(s);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0B0F13),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              Text(
                _done ? '量測結束（也可以看 logcat：OCRBENCH）' : '量測中…',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 12),
              for (final l in _lines)
                Text(
                  l,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
