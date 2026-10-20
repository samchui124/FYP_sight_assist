import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../vision/vision_session.dart';
import 'read_text_page.dart';
import 'demo_page.dart';

/// 主界面：**選一個模式**。
///
/// ## 為什麼要分成兩個模式（這是真機證據推出來的，不是偏好）
///
/// 引導與讀字會互搶，而且兩邊都因此變差：
///
/// - **CPU**：讀字一次 0.6–2.0 秒（1280×960），偵測一次 197 ms。
///   同時跑時讀字只能擠在偵測空檔。
/// - **語音**：真機實測招牌有**一半**被障礙物播報讓位丟掉（`spotDeferred` 12/22），
///   而且永遠不會補唸。
///
/// 兩顆按鈕讓使用者明確表達「我現在要哪一件事」，程式才知道該把
/// CPU 與語音優先給誰。
///
/// ## 無障礙考量
///
/// - **只有兩個可操作項**：全盲使用者從 App 啟動到「開始引導」只需
///   1 次焦點移動 + 雙擊（驗收清單要求 ≤ 4 次）。
/// - **標籤就是結果**：不用「模式一」「選項 A」這類要記憶的詞。
/// - **按鈕加大**（每個 72 高）：低視力使用者的觸控精確度通常較差，
///   而這是全 App 最常按的兩個東西。
/// - 每個模式都有一句說明，**進入後也會再播報一次**自己在哪裡。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.session});

  /// 相機與語音的共用持有者。預設自己建一個；測試注入假的。
  final VisionSession? session;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final VisionSession _session = widget.session ?? VisionSession();

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.current;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ExcludeSemantics(
                child: Text(
                  s.homeTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              _modeButton(
                icon: Icons.explore,
                label: s.modeGuidance,
                hint: s.modeGuidanceHint,
                onTap: () => _open(const DemoPage()),
              ),
              const SizedBox(height: 16),
              _modeButton(
                icon: Icons.text_fields,
                label: s.modeReadText,
                hint: s.modeReadTextHint,
                onTap: () => _open(ReadTextPage(session: _session)),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  /// 一個模式按鈕。**高度刻意做大**（72），並帶一句說明。
  ///
  /// 說明放在按鈕**內部**（而不是旁邊的小字）：這樣螢幕閱讀器會把
  /// 「標籤 + 說明」一起唸出來，使用者不必再多滑一次去讀說明。
  Widget _modeButton({
    required IconData icon,
    required String label,
    required String hint,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 72,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
