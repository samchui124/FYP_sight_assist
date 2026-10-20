/// 登入介面的文案。
///
/// ## 為什麼獨立成一個檔案，而不是加進 `l10n/app_strings.dart`
///
/// `app_strings.dart` 目前由另一條工作線在改（i18n 跟隨系統語言）。
/// 為了不製造衝突，登入的文案先獨立一份，**寫法完全照抄既有的模式**
/// （英文為預設、`_zh` 分支、由 `AppLocale.current` 決定）。
/// 之後要合併進 `AppStrings` 是單純的搬移，不是重寫。
///
/// 這是暫時的技術債，已記在 `docs/PROJECT-STATUS.md` 的風險表。
///
/// ## ★ 每一句都有「短版」與「長版」，這是刻意的
///
/// TalkBack 唸完一句需要時間。即時播報若太長，使用者還沒聽完就滑到下一項，
/// **那句話會被截斷，而他不會知道有東西沒聽到**。
///
/// 所以：
/// - `announceX` = 即時播報用，**控制在 12 個字以內**
/// - `x` = 畫面上顯示用，可以完整說明
///
/// **兩者不是同一份文字。** 錯誤的詳細說明放在畫面上讓使用者自己滑過去讀，
/// 即時播報只給最短的那一句。這個取捨見
/// `docs/A11Y-LOGIN-VISUAL-DESIGN.md` 第 9.5 節。
library;

import '../l10n/app_locale.dart';
import 'auth_service.dart';

class AuthStrings {
  const AuthStrings._(this.language);

  final AppLanguage language;

  static AuthStrings of(AppLanguage language) => AuthStrings._(language);

  static AuthStrings get current => AuthStrings._(AppLocale.current);

  bool get _zh => language == AppLanguage.zh;

  // ---- 頁面本身 ----

  String get title => _zh ? '登入領路通' : 'Sign in';

  String get intro => _zh
      ? '登入後可以把未識別的障礙物上傳。不登入也能引導。'
      : 'Sign in to upload obstacles we could not recognise. '
          'Guidance works without signing in.';

  String get announceEntry =>
      _zh ? '登入頁。可以跳過。' : 'Sign in page. Skippable.';

  // ---- 登入方式（標籤一律是「動作 + 結果」）----

  String get signInWithPasskey => _zh ? '用指紋登入' : 'Sign in with fingerprint';

  String get signInWithGoogle => _zh ? '用 Google 帳號登入' : 'Sign in with Google';

  String get signInWithApple => _zh ? '用 Apple 帳號登入' : 'Sign in with Apple';

  String get useEmail => _zh ? '用電子郵件登入' : 'Use email instead';

  String get notNow => _zh ? '稍後再說' : 'Not now';

  /// 首次查詢「這台裝置能用哪些方式」的期間顯示。
  /// 沒有這一句的話，載入期間畫面是空的，而**空白畫面沒有聲音等於沒有回饋**。
  String get loading =>
      _zh ? '正在準備登入方式，請稍候。' : 'Getting the sign in methods ready.';

  // ---- 電子郵件兩步 ----

  String get emailLabel => _zh ? '電子郵件地址' : 'Email address';

  String get sendCode => _zh ? '寄送驗證碼' : 'Send code';

  String get codeLabel => _zh ? '驗證碼' : 'Verification code';

  String get verifyAndSignIn => _zh ? '驗證並登入' : 'Verify and sign in';

  /// 提示可以貼上。WCAG 2.2 SC 3.3.8 要求不得阻止貼上。
  String get codeHint => _zh
      ? '可以從通知複製後貼上，不必記下來。'
      : 'You can paste it from the notification.';

  // ---- 狀態：短版播報 + 長版畫面 ----

  String get announceSigningIn => _zh ? '正在登入' : 'Signing in';

  String get signingIn => _zh ? '正在登入，請稍候。' : 'Signing in. One moment.';

  String get announceSignedIn => _zh ? '登入成功' : 'Signed in';

  String get signedIn => _zh ? '登入成功。' : 'Signed in.';

  /// ★ 取消**不是錯誤**，文案不可以出現「失敗」「錯誤」。
  String get announceCancelled => _zh ? '已取消' : 'Cancelled';

  String get cancelled => _zh ? '已取消，沒有登入。' : 'Cancelled. You are not signed in.';

  String get announceNetworkError => _zh ? '連不上網路' : 'No network';

  String get networkError => _zh
      ? '連不上網路。引導功能不受影響，可以先選「稍後再說」。'
      : 'Cannot reach the network. Guidance still works, '
          'or choose Not now.';

  String get announceNoBiometric => _zh ? '這台手機沒設定指紋' : 'No fingerprint set up';

  String get noBiometric => _zh
      ? '這台手機沒設定指紋或臉部辨識。可以改用 Google 帳號登入。'
      : 'This phone has no fingerprint or face unlock set up. '
          'You can use Google instead.';

  String get announceLocked => _zh ? '帳號暫時被鎖' : 'Account locked';

  String get locked => _zh
      ? '帳號暫時被鎖住了。可以聯絡客服，或先選「稍後再說」繼續使用引導。'
      : 'The account is temporarily locked. You can contact support, '
          'or choose Not now and keep using guidance.';

  String get announceGenericError => _zh ? '登入沒成功' : 'Sign in failed';

  String get genericError => _zh ? '登入沒有成功，請再試一次。' : 'Sign in did not complete. Try again.';

  String get announceLastMethod => _zh ? '不能解除最後一個方式' : 'Cannot remove last method';

  String get lastMethod => _zh
      ? '這是最後一個登入方式，不能解除，否則帳號會鎖死。'
      : 'This is the only sign in method left. Removing it would lock you out.';

  String get retry => _zh ? '重試' : 'Try again';

  String get contactSupport => _zh ? '聯絡客服' : 'Contact support';

  String get close => _zh ? '關閉' : 'Close';

  // ---- 帳號連結 ----

  String get announceNeedsLinking => _zh ? '這個信箱已經有帳號' : 'Email already registered';

  String get linkingTitle => _zh ? '這個信箱已經有帳號' : 'This email already has an account';

  String linkingBody(AuthProviderName existing) => _zh
      ? '這個信箱之前用 ${existing.zh} 註冊過。要連結到原本的帳號嗎？'
      : 'This email was registered with ${existing.en}. '
          'Link the new method to that account?';

  /// ★ 兩個選項都用**物件**命名，不用「確定」「取消」。
  /// 只聽得到標籤時，「取消」不知道取消什麼。
  String get linkingKeep => _zh ? '不連結' : 'Do not link';

  String get linkingConfirm => _zh ? '連結' : 'Link';

  /// 把登入方式的名字插進句子裡用。
  String providerName(AuthProvider p) =>
      _zh ? p.displayName.zh : p.displayName.en;

  // ---- 帳號頁 ----

  String get accountTitle => _zh ? '帳號' : 'Account';

  String get linkedMethods => _zh ? '已連結的登入方式' : 'Linked sign in methods';

  String get signOut => _zh ? '登出' : 'Sign out';

  /// 帳號頁的主要動作。
  ///
  /// ★ 為什麼需要它：使用者的目的是「登入以便上傳」，登入完就該回到引導，
  /// 而不是停在帳號頁。**帳號頁沒有出口的話，使用者會以為自己卡住了。**
  /// 這個按鈕永遠顯示（不依賴宿主有沒有提供 callback）。
  String get backToGuidance => _zh ? '回到引導' : 'Back to guidance';

  String get announceSignedOut => _zh ? '已登出' : 'Signed out';

  // ---- 刪除帳號（破壞性）----

  String get deleteAccount => _zh ? '刪除帳號' : 'Delete account';

  String get deleteTitle => _zh ? '刪除帳號' : 'Delete account';

  String get deleteBody => _zh
      ? '這會永久刪除你的帳號與上傳紀錄。引導功能不受影響。'
      : 'This permanently deletes your account and uploads. '
          'Guidance still works.';

  /// ★ 破壞性對話框的兩個選項都用**物件**命名，不用「確定」「取消」。
  /// 只聽得到標籤時，「確定」不知道確定什麼。
  String get deleteKeep => _zh ? '保留帳號' : 'Keep account';

  String get deleteConfirm => _zh ? '刪除帳號' : 'Delete account';
}

/// 顯示 / 朗讀用的登入方式名稱。
///
/// 抽出來是因為對話框要把它插進句子裡，而句子需要的是名稱不是 enum。
enum AuthProviderName {
  passkey('fingerprint', '指紋'),
  google('Google', 'Google'),
  apple('Apple', 'Apple'),
  emailCode('email', '電子郵件');

  const AuthProviderName(this.en, this.zh);

  final String en;
  final String zh;
}

/// `AuthProvider` -> 可顯示/可朗讀的名稱。
///
/// 放在這裡而不是 `auth_service.dart`，是為了讓「服務層」不知道任何文案，
/// 文案的變動不需要碰邏輯層。
extension AuthProviderNaming on AuthProvider {
  AuthProviderName get displayName => switch (this) {
        AuthProvider.passkey => AuthProviderName.passkey,
        AuthProvider.google => AuthProviderName.google,
        AuthProvider.apple => AuthProviderName.apple,
        AuthProvider.emailCode => AuthProviderName.emailCode,
      };
}
