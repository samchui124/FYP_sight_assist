/// **只在真機上驗證登入頁用的入口，不是正式入口。**
///
/// ## 為什麼要有這個檔案
///
/// `AuthPage` 需要一個入口才能裝到手機上驗證，但 `main.dart` 與
/// `demo_page.dart` 正由另一條工作線在改。直接動那兩個檔案會製造衝突，
/// 所以改用 Flutter 的 `--target` 指定另一個入口：
///
/// ```
/// flutter build apk --debug --target=lib/main_auth_debug.dart
/// flutter install
/// ```
///
/// 驗證完把手機裝回正式入口即可：
/// ```
/// flutter build apk --debug        # 不帶 --target，回到 lib/main.dart
/// flutter install
/// ```
///
/// ## 為什麼要 `ensureSemantics()`
///
/// Flutter **只有在無障礙服務開啟時才會建立語意樹**。沒有開 TalkBack 的
/// 情況下，`adb shell uiautomator dump` 只會看到一個空白的 FlutterView，
/// 於是「沒有節點」與「節點是空的」在驗證時分不出來。
///
/// 先呼叫 `ensureSemantics()` 強制建立，語意樹就會真的送到 Android 的
/// 無障礙層，`uiautomator dump` 也才看得到每個節點的 `content-desc`。
/// 這樣就能**不開 TalkBack** 也驗證標籤是否正確。
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'auth/mock_auth_service.dart';
import 'l10n/app_locale.dart';
import 'tts/flutter_tts_speaker.dart';
import 'ui/auth_page.dart';

/// 必須保留這個 handle，否則語意樹會立刻被關掉。
final SemanticsHandle _semanticsHandle =
    SemanticsBinding.instance.ensureSemantics();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLocale.current = AppLocale.resolve();
  _semanticsHandle.hashCode; // 觸碰一下，避免被 lint 當成未使用的變數

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D32),
        brightness: Brightness.dark,
      ),
    ),
    home: AuthPage(
      // 假貨：不需要任何帳號或後端就能走完整流程。
      service: MockAuthService(),
      // 真的 TTS。TalkBack 關著時就是靠它唸，這條路徑要在真機上聽得到。
      speaker: FlutterTtsSpeaker(),
      onSkip: () {},
      // 登入成功後直接回到引導（真機上就是關掉這一頁）。
      onSignedIn: (_) => _leave(),
      onBackToGuidance: _leave,
    ),
  ));
}

/// 這個入口沒有引導頁可以回去，所以用一句 TTS 表示「回到引導了」。
/// 正式接進 App 時，這裡會是 `Navigator.pop`。
void _leave() {
  FlutterTtsSpeaker().speak('回到引導');
}
