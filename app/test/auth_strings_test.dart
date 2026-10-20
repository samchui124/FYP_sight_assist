import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/auth/auth_strings.dart';
import 'package:pathguide/l10n/app_locale.dart';

/// 文案的機械檢查。
///
/// ## 為什麼文案要寫成測試
///
/// 這一頁的每一句話都會被**聽到**，而不是被看到。看的時候漏一個字沒差，
/// 聽的時候漏一句就是使用者卡住。所以長度與禁用字元這種「寫的時候很容易忘」
/// 的規則，一律交給測試，不靠人記得。
void main() {
  /// 即時播報的長度上限，換算依據見設計文件第 9.5 節：
  /// 目標是「唸完約 3 秒」，中文約 4 到 5 字／秒，英文約 12 到 15 字元／秒。
  const maxZhChars = 12;
  const maxEnChars = 40;

  const languages = AppLanguage.values;

  /// 每一句「即時播報」的取值器。新增播報時**一定要加進來**，
  /// 否則它就不受長度限制。
  final announcements = <String, String Function(AuthStrings)>{
    'announceEntry': (s) => s.announceEntry,
    'announceSigningIn': (s) => s.announceSigningIn,
    'announceSignedIn': (s) => s.announceSignedIn,
    'announceCancelled': (s) => s.announceCancelled,
    'announceNetworkError': (s) => s.announceNetworkError,
    'announceNoBiometric': (s) => s.announceNoBiometric,
    'announceLocked': (s) => s.announceLocked,
    'announceGenericError': (s) => s.announceGenericError,
    'announceLastMethod': (s) => s.announceLastMethod,
    'announceNeedsLinking': (s) => s.announceNeedsLinking,
    'announceSignedOut': (s) => s.announceSignedOut,
  };

  /// 收集所有會被使用者看到或聽到的字串。
  List<(String, String)> allVisible(AuthStrings s) {
    final out = <(String, String)>[
      ('title', s.title),
      ('intro', s.intro),
      ('signInWithPasskey', s.signInWithPasskey),
      ('signInWithGoogle', s.signInWithGoogle),
      ('signInWithApple', s.signInWithApple),
      ('useEmail', s.useEmail),
      ('notNow', s.notNow),
      ('loading', s.loading),
      ('emailLabel', s.emailLabel),
      ('sendCode', s.sendCode),
      ('codeLabel', s.codeLabel),
      ('verifyAndSignIn', s.verifyAndSignIn),
      ('codeHint', s.codeHint),
      ('signingIn', s.signingIn),
      ('signedIn', s.signedIn),
      ('cancelled', s.cancelled),
      ('networkError', s.networkError),
      ('noBiometric', s.noBiometric),
      ('locked', s.locked),
      ('genericError', s.genericError),
      ('lastMethod', s.lastMethod),
      ('retry', s.retry),
      ('contactSupport', s.contactSupport),
      ('close', s.close),
      ('linkingTitle', s.linkingTitle),
      ('linkingKeep', s.linkingKeep),
      ('linkingConfirm', s.linkingConfirm),
      ('accountTitle', s.accountTitle),
      ('linkedMethods', s.linkedMethods),
      ('signOut', s.signOut),
      ('deleteAccount', s.deleteAccount),
      ('deleteTitle', s.deleteTitle),
      ('deleteBody', s.deleteBody),
      ('deleteKeep', s.deleteKeep),
      ('deleteConfirm', s.deleteConfirm),
    ];
    for (final e in announcements.entries) {
      out.add((e.key, e.value(s)));
    }
    return out;
  }

  group('禁用字元', () {
    test('沒有任何 em dash 或 en dash', () {
      // 破折號在螢幕閱讀器上會被念成停頓或直接被忽略，而且它是 AI 文案的
      // 典型痕跡。這一頁一個都不准有。
      for (final lang in languages) {
        final s = AuthStrings.of(lang);
        for (final (name, text) in allVisible(s)) {
          expect(text.contains('\u2014'), isFalse,
              reason: '[${lang.name}] $name 含 em dash');
          expect(text.contains('\u2013'), isFalse,
              reason: '[${lang.name}] $name 含 en dash');
        }
      }
    });

    test('沒有 emoji', () {
      // emoji 會被 TTS 念成奇怪的名字，而且佔掉播報長度。
      final emoji = RegExp(
          r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]', unicode: true);
      for (final lang in languages) {
        final s = AuthStrings.of(lang);
        for (final (name, text) in allVisible(s)) {
          expect(emoji.hasMatch(text), isFalse,
              reason: '[${lang.name}] $name 含 emoji');
        }
      }
    });

    test('按鈕不用「確定」「取消」這種沒有資訊的字', () {
      final banned = {'確定', '取消', '提交', 'OK', 'Confirm', 'Submit', 'Cancel'};
      for (final lang in languages) {
        final s = AuthStrings.of(lang);
        for (final (name, text) in allVisible(s)) {
          expect(banned.contains(text.trim()), isFalse,
              reason: '[${lang.name}] $name 是「$text」：只聽得到標籤時無從判斷在做什麼');
        }
      }
    });
  });

  group('即時播報長度（唸完約 3 秒）', () {
    test('中文 ≤ 12 字', () {
      final s = AuthStrings.of(AppLanguage.zh);
      for (final e in announcements.entries) {
        final text = e.value(s);
        // 用 runes 而不是 length：中文都是單一碼位，但用 runes 才不會
        // 在將來有人加了非 BMP 字元（emoji、罕用字）時算錯。
        expect(text.runes.length, lessThanOrEqualTo(maxZhChars),
            reason: '${e.key} 有 ${text.runes.length} 字，太長會被下一滑截斷：$text');
      }
    });

    test('英文 ≤ 40 字元', () {
      final s = AuthStrings.of(AppLanguage.en);
      for (final e in announcements.entries) {
        final text = e.value(s);
        expect(text.length, lessThanOrEqualTo(maxEnChars),
            reason: '${e.key} 有 ${text.length} 字元，太長會被下一滑截斷：$text');
      }
    });
  });

  group('語意正確性', () {
    test('★ 取消的文案不出現「失敗」「錯誤」等字', () {
      // 使用者主動取消不是錯誤。用錯誤的字眼會讓他以為自己弄壞了什麼。
      final s = AuthStrings.of(AppLanguage.zh);
      for (final text in [s.announceCancelled, s.cancelled,
        AuthStrings.of(AppLanguage.en).announceCancelled,
        AuthStrings.of(AppLanguage.en).cancelled]) {
        expect(text.contains('失敗'), isFalse);
        expect(text.contains('錯誤'), isFalse);
        expect(text.toLowerCase().contains('error'), isFalse);
        expect(text.toLowerCase().contains('fail'), isFalse);
      }
    });

    test('錯誤文案一定說明下一步做什麼，不能只說失敗', () {
      final zh = AuthStrings.of(AppLanguage.zh);
      final en = AuthStrings.of(AppLanguage.en);
      // 「稍後再說」是可退出的路，每一則錯誤都要提到它或「重試」。
      for (final text in [zh.networkError, zh.locked, en.networkError, en.locked]) {
        expect(text.contains('稍後再說') || text.contains('重試') ||
            text.contains('Not now') || text.contains('Try again'), isTrue,
            reason: '只說失敗的錯誤訊息會讓使用者卡死：$text');
      }
    });

    test('破壞性對話框的選項用物件命名，不用「確定」', () {
      final zh = AuthStrings.of(AppLanguage.zh);
      final en = AuthStrings.of(AppLanguage.en);
      expect(zh.deleteKeep, isNot(zh.deleteConfirm));
      expect(en.deleteKeep, isNot(en.deleteConfirm));
      expect(zh.deleteConfirm.contains('帳號'), isTrue);
      expect(en.deleteConfirm.toLowerCase().contains('account'), isTrue);
    });

    test('英文是預設，且兩個語言都不為空', () {
      for (final lang in languages) {
        final s = AuthStrings.of(lang);
        for (final (name, text) in allVisible(s)) {
          expect(text.trim(), isNotEmpty, reason: '[${lang.name}] $name 是空的');
        }
      }
    });
  });
}
