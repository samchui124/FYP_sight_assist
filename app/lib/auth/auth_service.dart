/// 登入功能的介面與資料模型。
///
/// ## 這一層刻意不含任何網路或第三方 SDK
///
/// 真實的登入（Google / Apple / 通行密鑰）需要主控台設定、OAuth 憑證、
/// 甚至一台 Mac。但**登入真正的難點不是連上伺服器，是盲人使用者能不能
/// 自己走完流程而不迷路**。這件事與後端完全無關：語意標籤、焦點順序、
/// 錯誤播報、逾時處理，換成任何後端都一模一樣。
///
/// 所以先把介面與流程做完並用測試釘死，之後接後端時只需要換掉
/// [AuthService] 的實作，畫面與測試都不動。
///
/// 本專案本來就是這個套路：`app/lib/vision/mock_vision_source.dart`
/// 就是相機的假貨，讓整個畫面與測試能在沒有相機的情況下跑起來。
library;

/// 使用者可以選擇的登入方式。
///
/// 順序不是隨便排的，是「打字量」排序，見
/// `docs/A11Y-ENTRY-AND-AUTH.md` 第 4.1 節：
/// 通行密鑰與第三方帳號都是零打字，電子郵件驗證碼次之，密碼最差
/// （WCAG 2.2 SC 3.3.8 把「從記憶裡打密碼」視為認知功能測試）。
enum AuthProvider {
  /// 通行密鑰（指紋 / 臉部）。零打字，最適合全盲使用者。
  passkey,

  /// Google 帳號。
  google,

  /// Apple 帳號。iOS 上若提供 Google，App Store 審核 4.8 強制也要提供這個。
  apple,

  /// 電子郵件一次性驗證碼。保底方式，必須允許貼上。
  emailCode,
}

/// 失敗的原因。
///
/// ★ 每一種都必須在畫面上有**對應的一句播報**與**一個出口**。
/// 少一種的後果是：使用者按下按鈕之後沒有任何反應，他看不到轉圈圈，
/// 於是會以為程式壞了並一直重複按。
enum AuthProblem {
  /// 連不上網路。
  network,

  /// 這台裝置無法提供該方式：沒設指紋、Play 服務缺失、iOS 未登入 Apple 帳號。
  providerUnavailable,

  /// 帳號被鎖。
  accountLocked,

  /// 伺服器明確拒絕。
  rejected,

  /// 拒絕的原因是「這是最後一個登入方式」。
  ///
  /// 允許解除最後一個，帳號就鎖死了，所以服務層必須拒絕
  /// （不能只靠在畫面上把按鈕藏起來）。
  lastSignInMethod,

  /// 其他未分類錯誤。
  unknown,
}

/// 已登入的帳號。
///
/// 只放畫面與同步真的需要的欄位，不放權杖。權杖屬於儲存層，
/// 不該在畫面之間流動。
final class AuthAccount {
  const AuthAccount({
    required this.id,
    required this.email,
    required this.displayName,
    required this.providers,
    this.emailIsPrivateRelay = false,
  });

  final String id;
  final String email;
  final String displayName;

  /// 這個帳號目前掛了哪些登入方式（一個帳號可以掛多個）。
  final Set<AuthProvider> providers;

  /// Apple 的「隱藏我的電子郵件」會給一個轉發地址。
  ///
  /// ★ 必須記住這件事：轉發地址**不是**使用者的真實信箱，
  /// 所以不能拿它去跟其他方式登入的同一個人自動合併帳號。
  final bool emailIsPrivateRelay;

  AuthAccount withProvider(AuthProvider p) => AuthAccount(
        id: id,
        email: email,
        displayName: displayName,
        providers: {...providers, p},
        emailIsPrivateRelay: emailIsPrivateRelay,
      );

  AuthAccount withoutProvider(AuthProvider p) => AuthAccount(
        id: id,
        email: email,
        displayName: displayName,
        providers: {...providers}..remove(p),
        emailIsPrivateRelay: emailIsPrivateRelay,
      );

  @override
  bool operator ==(Object other) =>
      other is AuthAccount &&
      other.id == id &&
      other.email == email &&
      other.displayName == displayName &&
      other.emailIsPrivateRelay == emailIsPrivateRelay &&
      other.providers.length == providers.length &&
      other.providers.containsAll(providers);

  @override
  int get hashCode => Object.hash(
        id,
        email,
        displayName,
        emailIsPrivateRelay,
        Object.hashAllUnordered(providers),
      );

  @override
  String toString() =>
      'AuthAccount($id, $email, providers=${providers.map((p) => p.name).toList()..sort()})';
}

/// 登入嘗試的結果。
///
/// ## 為什麼用 sealed class 而不是丟例外
///
/// `sealed` 讓編譯器**強制**畫面處理每一個分支，少寫一個就編譯不過。
/// 這件事對盲人使用者特別重要：漏掉一個錯誤分支的後果是
/// **按下按鈕之後沒有任何聲音**，而他唯一的回饋就是聲音。
/// 用例外的話，漏掉一個 `catch` 只有真的執行到才會發現。
///
/// 另外，**「使用者取消」不是錯誤**。他按了返回、關掉 Google 的畫面，
/// 這是完全正常的行為，不該報錯也不該嚇他，所以它有自己的一個分支。
sealed class AuthResult {
  const AuthResult();
}

/// 成功。
final class SignedIn extends AuthResult {
  const SignedIn(this.account);
  final AuthAccount account;
}

/// 使用者自己取消。**不是錯誤。**
final class AuthCancelled extends AuthResult {
  const AuthCancelled();
}

/// 失敗。[problem] 決定要播報哪一句。
final class AuthFailed extends AuthResult {
  const AuthFailed(this.problem);
  final AuthProblem problem;
}

/// 這個電子郵件已經用別的方式註冊過，需要使用者決定要不要連結。
///
/// ★ 這是**必須問**而不能自己決定的一步：靜默地再建一個帳號，
/// 會讓使用者下次用另一種方式登入時發現資料不見了。
final class NeedsLinking extends AuthResult {
  const NeedsLinking({required this.email, required this.existing});
  final String email;

  /// 原本是用哪一種方式註冊的。
  final AuthProvider existing;
}

/// 登入服務。
///
/// 實作有兩個：`MockAuthService`（假貨，用於開發與測試）
/// 與將來的真實後端實作。畫面只依賴這個介面。
abstract interface class AuthService {
  /// 這台裝置現在**能用**哪些登入方式。
  ///
  /// ★ 必須先問再顯示，不能「先顯示、失敗了再說」。
  /// 手機沒設指紋時還顯示通行密鑰按鈕，對全盲使用者是純粹的陷阱：
  /// 他按了、被拒、而且不知道為什麼。
  Future<Set<AuthProvider>> availableProviders();

  /// 之前登入過就直接拿回帳號（「記住我」的讀取端）。
  Future<AuthAccount?> restore();

  Future<AuthResult> signIn(AuthProvider provider);

  /// 電子郵件驗證碼分成兩步：寄出、驗證。
  Future<AuthResult> requestEmailCode(String email);
  Future<AuthResult> verifyEmailCode(String email, String code);

  /// 連結一個新的登入方式到目前帳號。
  Future<AuthResult> linkProvider(AuthProvider provider);

  /// 解除一個登入方式。
  ///
  /// 若這是最後一個，必須回 [AuthFailed] 帶著
  /// [AuthProblem.lastSignInMethod]，**不可以**成功。
  Future<AuthResult> unlinkProvider(AuthProvider provider);

  Future<void> signOut();

  /// 刪除帳號。應用程式內必須可用，不能要求使用者聯絡客服。
  Future<void> deleteAccount();
}
