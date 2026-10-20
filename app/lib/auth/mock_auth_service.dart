/// 登入服務的假貨（stub）。用於開發與測試。
///
/// ## ★ 這個假貨最重要的一個性質：它可以「故意失敗」
///
/// 如果假貨永遠成功，那「載入中」「連不上」「使用者取消」「這個信箱已註冊過」
/// 這些分支**永遠不會被執行到**，也就永遠不會被測試到。
/// 而那些正是全盲使用者真正會卡住的地方。
///
/// **永遠成功的假貨，等於沒有測試。**
///
/// ## 佇列與預設結果的規則（測試要依賴這個，所以寫清楚）
///
/// 1. 任何**回傳 [AuthResult] 的方法**都會先從 [scripted] 佇列取一個結果，
///    取的順序就是呼叫順序。
/// 2. 佇列用完之後，回傳 [fallback]；若 [fallback] 是 null，就回傳預設的成功帳號。
/// 3. [AuthService.availableProviders] **不消耗**佇列（它不回傳 [AuthResult]）。
/// 4. 要求一個不在 [available] 裡的方式，會在**消耗佇列之前**就短路回
///    [AuthProblem.providerUnavailable]。因為「不該顯示的按鈕被按了」
///    是畫面層的錯，不該讓呼叫者能用佇列掩蓋過去。
library;

import 'auth_service.dart';
import 'session_store.dart';

final class MockAuthService implements AuthService {
  MockAuthService({
    this.delay = Duration.zero,
    Set<AuthProvider>? available,
    List<AuthResult>? scripted,
    this.fallback,
    AuthAccount? initialAccount,
    SessionStore? store,
  })  : available = available ??
            const {
              AuthProvider.passkey,
              AuthProvider.google,
              AuthProvider.apple,
              AuthProvider.emailCode,
            },
        _queue = List<AuthResult>.of(scripted ?? const []),
        _store = store ?? InMemorySessionStore(),
        _current = initialAccount;

  /// 每次呼叫延遲多久。用來測「按下後必須立刻有聲音」：
  /// 設成幾秒，然後斷言在延遲結束之前就已經有播報。
  final Duration delay;

  final Set<AuthProvider> available;

  /// 依序吐出的結果。
  final List<AuthResult> _queue;

  /// 佇列用完之後的結果。null 表示回傳預設成功。
  final AuthResult? fallback;

  final SessionStore _store;

  AuthAccount? _current;

  /// 呼叫紀錄，讓測試可以斷言「按一次只呼叫一次」。
  final List<String> calls = <String>[];

  /// 還沒被消耗的佇列長度（測試用）。
  int get pending => _queue.length;

  /// 預設的成功帳號。刻意寫得很假，避免有人誤以為是真實資料。
  static const AuthAccount defaultAccount = AuthAccount(
    id: 'mock-0001',
    email: 'mock.user@pathguide.test',
    displayName: 'Mock User',
    providers: {AuthProvider.google},
  );

  // ---- 常見情境的現成建構子 ----

  /// 每次都連不上。
  factory MockAuthService.offline() =>
      MockAuthService(fallback: const AuthFailed(AuthProblem.network));

  /// 使用者每次都取消。**取消不是錯誤**，所以回傳的是 AuthCancelled。
  factory MockAuthService.cancelled() =>
      MockAuthService(fallback: const AuthCancelled());

  /// 每次都回得很慢。用來測「按下後立刻要有回饋」。
  factory MockAuthService.slow(
          [Duration d = const Duration(seconds: 3)]) =>
      MockAuthService(delay: d);

  /// 這台裝置沒有通行密鑰（沒設指紋）。密鑰按鈕不該出現。
  factory MockAuthService.biometricMissing() => MockAuthService(
        available: const {
          AuthProvider.google,
          AuthProvider.apple,
          AuthProvider.emailCode,
        },
      );

  /// 這個信箱已經用別的方式註冊過。
  factory MockAuthService.needsLinking(
    String email, {
    AuthProvider existing = AuthProvider.google,
  }) =>
      MockAuthService(
        fallback: NeedsLinking(email: email, existing: existing),
      );

  /// 已經登入過的狀態。
  factory MockAuthService.signedIn(AuthAccount account) {
    final store = InMemorySessionStore(account);
    return MockAuthService(initialAccount: account, store: store);
  }

  // ---- 內部 ----

  /// 記錄呼叫，並（必要時）延遲。
  ///
  /// [local] 為 true 表示這是**本機查詢**（讀儲存、問裝置支援哪些方式），
  /// 不模擬網路延遲。理由：`delay` 的用途是模擬「登入要等伺服器」，
  /// 把本機查詢也一起延遲會讓頁面在開頭有一段什麼都沒有的空窗，
  /// 那是 mock 造成的假象，不是真實現象。
  Future<T> _record<T>(String name, Future<T> Function() body,
      {bool local = false}) async {
    calls.add(name);
    if (!local && delay > Duration.zero) await Future<void>.delayed(delay);
    return body();
  }

  /// 取出下一個結果：先看佇列，再看 fallback，最後才是預設成功。
  AuthResult _nextSignedIn() {
    if (_queue.isNotEmpty) return _queue.removeAt(0);
    return fallback ?? const SignedIn(defaultAccount);
  }

  Future<AuthResult> _applyAuthResult(AuthResult r) async {
    switch (r) {
      case SignedIn(:final account):
        _current = account;
        await _store.write(account);
      case AuthCancelled():
        break; // 取消不動任何狀態
      case AuthFailed():
        break;
      case NeedsLinking():
        break; // 還沒決定要不要連結，帳號不能建
    }
    return r;
  }

  // ---- AuthService ----

  @override
  Future<Set<AuthProvider>> availableProviders() async => available;

  @override
  Future<AuthAccount?> restore() => _record('restore', () async {
        _current ??= await _store.read();
        return _current;
      }, local: true);

  @override
  Future<AuthResult> signIn(AuthProvider provider) => _record('signIn', () async {
        // ★ 先檢查可用性，並且**不消耗佇列**：不該顯示的按鈕被按了，
        //   是畫面層的錯，不該讓呼叫者用佇列把它掩蓋過去。
        if (!available.contains(provider)) {
          return const AuthFailed(AuthProblem.providerUnavailable);
        }
        return _applyAuthResult(_nextSignedIn());
      });

  @override
  Future<AuthResult> requestEmailCode(String email) =>
      _record('requestEmailCode', () async {
        if (!available.contains(AuthProvider.emailCode)) {
          return const AuthFailed(AuthProblem.providerUnavailable);
        }
        return _applyAuthResult(_nextSignedIn());
      });

  @override
  Future<AuthResult> verifyEmailCode(String email, String code) =>
      _record('verifyEmailCode', () async {
        if (code.trim().isEmpty) {
          return const AuthFailed(AuthProblem.rejected);
        }
        return _applyAuthResult(_nextSignedIn());
      });

  @override
  Future<AuthResult> linkProvider(AuthProvider provider) =>
      _record('linkProvider', () async {
        final r = _nextSignedIn();
        if (r is! SignedIn) return _applyAuthResult(r);
        // 連結是「加到目前帳號」，不是「換一個帳號」。
        final base = _current ?? r.account;
        return _applyAuthResult(SignedIn(base.withProvider(provider)));
      });

  @override
  Future<AuthResult> unlinkProvider(AuthProvider provider) =>
      _record('unlinkProvider', () async {
        final account = _current;
        if (account == null) {
          return const AuthFailed(AuthProblem.rejected);
        }
        if (!account.providers.contains(provider)) {
          return const AuthFailed(AuthProblem.rejected);
        }
        // ★ 這條不變量必須在服務層擋，不能只靠在畫面上把按鈕藏起來。
        //   允許解除最後一個登入方式，帳號就鎖死了。
        if (account.providers.length <= 1) {
          return const AuthFailed(AuthProblem.lastSignInMethod);
        }
        return _applyAuthResult(SignedIn(account.withoutProvider(provider)));
      });

  @override
  Future<void> signOut() => _record('signOut', () async {
        _current = null;
        await _store.write(null);
      });

  @override
  Future<void> deleteAccount() => _record('deleteAccount', () async {
        _current = null;
        await _store.write(null);
      });
}
