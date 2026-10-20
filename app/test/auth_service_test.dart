import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/auth/auth_service.dart';
import 'package:pathguide/auth/mock_auth_service.dart';
import 'package:pathguide/auth/session_store.dart';

/// 登入服務的介面契約與假貨行為。
///
/// ## 為什麼要單獨測「假貨本身」
///
/// 這個檔案有一半的測試是在測 [MockAuthService]。看起來多餘，但它防的是
/// 一種很隱蔽的失敗：**如果假貨寫錯了，所有依賴它的測試都會因為錯的理由而通過。**
/// 例如假貨的佇列用完了卻偷偷回成功，那「錯誤處理」的測試就永遠測不到錯誤。
///
/// 所以佇列與預設結果的規則必須被獨立釘死。
void main() {
  const account = MockAuthService.defaultAccount;

  group('假貨的佇列規則', () {
    test('依序吐出腳本結果', () async {
      final svc = MockAuthService(scripted: const [
        AuthFailed(AuthProblem.network),
        AuthCancelled(),
      ]);

      expect(await svc.signIn(AuthProvider.google), isA<AuthFailed>());
      expect(await svc.signIn(AuthProvider.google), isA<AuthCancelled>());
    });

    test('佇列用完後回傳 fallback', () async {
      final svc = MockAuthService(
        scripted: const [AuthFailed(AuthProblem.network)],
        fallback: const AuthFailed(AuthProblem.accountLocked),
      );

      expect(await svc.signIn(AuthProvider.google), isA<AuthFailed>());
      final second = await svc.signIn(AuthProvider.google);
      expect(second, isA<AuthFailed>());
      expect((second as AuthFailed).problem, AuthProblem.accountLocked);
    });

    test('沒有 fallback 時，佇列用完回傳預設成功', () async {
      final svc = MockAuthService();
      final r = await svc.signIn(AuthProvider.google);
      expect(r, isA<SignedIn>());
      expect((r as SignedIn).account, account);
    });

    test('availableProviders 不消耗佇列', () async {
      final svc = MockAuthService(scripted: const [AuthCancelled()]);
      await svc.availableProviders();
      await svc.availableProviders();
      expect(svc.pending, 1, reason: '不該因為查詢可用方式就把腳本吃掉');
    });

    test('要求不可用的方式會短路，且不消耗佇列', () async {
      final svc = MockAuthService(
        available: const {AuthProvider.google},
        scripted: const [AuthCancelled()],
      );

      final r = await svc.signIn(AuthProvider.passkey);
      expect(r, isA<AuthFailed>());
      expect((r as AuthFailed).problem, AuthProblem.providerUnavailable);
      expect(svc.pending, 1,
          reason: '不該顯示的按鈕被按了，是畫面的錯，不該被佇列掩蓋過去');
    });

    test('紀錄每一次呼叫，且順序正確', () async {
      final svc = MockAuthService();
      await svc.availableProviders();
      await svc.restore();
      await svc.signIn(AuthProvider.google);
      expect(svc.calls, ['restore', 'signIn']);
    });
  });

  group('狀態不變量', () {
    test('取消不會建立帳號', () async {
      final store = InMemorySessionStore();
      final svc = MockAuthService(
        fallback: const AuthCancelled(),
        store: store,
      );

      await svc.signIn(AuthProvider.google);
      expect(store.peek, isNull, reason: '取消不該留下任何帳號');
      expect(await svc.restore(), isNull);
    });

    test('失敗不會建立帳號', () async {
      final store = InMemorySessionStore();
      final svc = MockAuthService(
        fallback: const AuthFailed(AuthProblem.network),
        store: store,
      );

      await svc.signIn(AuthProvider.google);
      expect(store.peek, isNull);
    });

    test('NeedsLinking 不會建立帳號（還沒決定要不要連結）', () async {
      final store = InMemorySessionStore();
      final svc = MockAuthService(
        fallback: const NeedsLinking(
          email: 'someone@example.com',
          existing: AuthProvider.google,
        ),
        store: store,
      );

      final r = await svc.signIn(AuthProvider.apple);
      expect(r, isA<NeedsLinking>());
      expect((r as NeedsLinking).email, 'someone@example.com');
      expect(store.peek, isNull);
    });

    test('成功會寫入儲存，restore 拿得回來', () async {
      final store = InMemorySessionStore();
      final svc = MockAuthService(store: store);

      await svc.signIn(AuthProvider.google);
      expect(store.peek, account);

      // 換一個服務實例（模擬重開 App），應該從儲存拿回同一帳號。
      final fresh = MockAuthService(store: store);
      expect(await fresh.restore(), account);
    });

    test('登出會清掉儲存', () async {
      final svc = MockAuthService(store: InMemorySessionStore());
      await svc.signIn(AuthProvider.google);
      await svc.signOut();
      expect(await svc.restore(), isNull);
    });

    test('刪除帳號會清掉儲存', () async {
      final svc = MockAuthService(store: InMemorySessionStore());
      await svc.signIn(AuthProvider.google);
      await svc.deleteAccount();
      expect(await svc.restore(), isNull);
    });
  });

  group('帳號綁定', () {
    test('連結會加一個方式，身分不變', () async {
      final svc = MockAuthService();
      await svc.signIn(AuthProvider.google);

      final r = await svc.linkProvider(AuthProvider.apple);
      expect(r, isA<SignedIn>());
      final linked = (r as SignedIn).account;
      expect(linked.id, account.id);
      expect(linked.email, account.email);
      expect(linked.providers, containsAll([AuthProvider.google, AuthProvider.apple]));
    });

    test('解除非最後一個方式會成功移除', () async {
      final multi = account.withProvider(AuthProvider.apple);
      final svc = MockAuthService.signedIn(multi);

      final r = await svc.unlinkProvider(AuthProvider.apple);
      expect(r, isA<SignedIn>());
      expect((r as SignedIn).account.providers, {AuthProvider.google});
    });

    test('★ 解除最後一個方式必須被拒絕', () async {
      final svc = MockAuthService.signedIn(account);
      expect(account.providers.length, 1, reason: '這個測試要求起始狀態只有一個方式');

      final r = await svc.unlinkProvider(AuthProvider.google);
      expect(r, isA<AuthFailed>());
      expect((r as AuthFailed).problem, AuthProblem.lastSignInMethod);

      final still = await svc.restore();
      expect(still!.providers, {AuthProvider.google},
          reason: '被拒絕的操作不可以偷偷改動狀態');
    });

    test('解除不存在的方式會被拒絕', () async {
      final svc = MockAuthService.signedIn(account);
      final r = await svc.unlinkProvider(AuthProvider.apple);
      expect(r, isA<AuthFailed>());
      expect((r as AuthFailed).problem, AuthProblem.rejected);
    });
  });

  group('模型', () {
    test('withProvider / withoutProvider 不會動到原物件', () {
      final a = account.withProvider(AuthProvider.apple);
      final b = a.withoutProvider(AuthProvider.apple);
      expect(a.providers, containsAll([AuthProvider.google, AuthProvider.apple]));
      expect(b.providers, {AuthProvider.google});
    });

    test('相等性看所有欄位，且與集合順序無關', () {
      const x = AuthAccount(
        id: 'i',
        email: 'e@x.test',
        displayName: 'n',
        providers: {AuthProvider.google, AuthProvider.apple},
      );
      const y = AuthAccount(
        id: 'i',
        email: 'e@x.test',
        displayName: 'n',
        providers: {AuthProvider.apple, AuthProvider.google},
      );
      expect(x, y);
      expect(x.hashCode, y.hashCode);
    });

    test('Apple 的轉發信箱必須被標記出來', () {
      const relay = AuthAccount(
        id: 'i',
        email: 'abc@privaterelay.appleid.com',
        displayName: 'n',
        providers: {AuthProvider.apple},
        emailIsPrivateRelay: true,
      );
      const plain = AuthAccount(
        id: 'i',
        email: 'abc@privaterelay.appleid.com',
        displayName: 'n',
        providers: {AuthProvider.apple},
      );
      // 同一個轉發地址與同一個真實地址不可以被當成同一個帳號
      expect(relay == plain, isFalse);
    });
  });

  group('結果型別的窮盡性', () {
    test('每一種 AuthResult 都有處理，且對應到不同的畫面行為', () {
      // 這個 switch 是**編譯期**證明：AuthResult 是 sealed，
      // 少寫一個分支就編譯不過。所以這段程式碼本身就是測試。
      String describe(AuthResult r) => switch (r) {
            SignedIn(:final account) => 'signed-in:${account.id}',
            AuthCancelled() => 'cancelled',
            AuthFailed(:final problem) => 'failed:${problem.name}',
            NeedsLinking(:final email, :final existing) =>
              'needs-linking:$email:${existing.name}',
          };

      expect(describe(const AuthCancelled()), 'cancelled');
      expect(describe(const AuthFailed(AuthProblem.network)), 'failed:network');
      expect(describe(const SignedIn(account)), 'signed-in:mock-0001');
      expect(
        describe(const NeedsLinking(
            email: 'a@b.test', existing: AuthProvider.apple)),
        'needs-linking:a@b.test:apple',
      );
    });

    test('取消與失敗是不同的分支，取消不能被當成錯誤播報', () {
      // 這是設計決定，不是實作細節：使用者主動取消不該聽到「錯誤」。
      expect(const AuthCancelled() is AuthFailed, isFalse);
    });
  });
}
