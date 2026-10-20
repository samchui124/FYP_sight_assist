import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/auth/auth_service.dart';
import 'package:pathguide/auth/mock_auth_service.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/ui/auth_page.dart';

/// 記錄被要求唸出的句子，用來斷言「誰出聲」。
class RecordingSpeaker implements Speaker {
  final List<String> spoken = [];

  /// 回傳 null：不觸發「語音包與系統語言不符」那條警告台詞。
  @override
  Future<String?> initialize() async => null;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  Future<List<String>> languages() async => const ['en-US'];
}

/// `availableProviders()` 很慢的服務。
///
/// 用來測「首次查詢期間畫面不能是空白的」。其他方法全部委派給真正的假貨，
/// 所以這個類別只負責一件事，不會變成第二套實作。
class _SlowBootstrapService implements AuthService {
  final MockAuthService _inner = MockAuthService();

  @override
  Future<Set<AuthProvider>> availableProviders() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    return _inner.availableProviders();
  }

  @override
  Future<AuthAccount?> restore() => _inner.restore();

  @override
  Future<AuthResult> signIn(AuthProvider provider) => _inner.signIn(provider);

  @override
  Future<AuthResult> requestEmailCode(String email) =>
      _inner.requestEmailCode(email);

  @override
  Future<AuthResult> verifyEmailCode(String email, String code) =>
      _inner.verifyEmailCode(email, code);

  @override
  Future<AuthResult> linkProvider(AuthProvider provider) =>
      _inner.linkProvider(provider);

  @override
  Future<AuthResult> unlinkProvider(AuthProvider provider) =>
      _inner.unlinkProvider(provider);

  @override
  Future<void> signOut() => _inner.signOut();

  @override
  Future<void> deleteAccount() => _inner.deleteAccount();
}

void main() {
  late RecordingSpeaker speaker;
  var haptics = 0;

  setUp(() {
    speaker = RecordingSpeaker();
    haptics = 0;
  });

  /// 把頁面裝起來。
  ///
  /// [screenReaderOn] 直接映射到 `MediaQuery.accessibleNavigation`，
  /// 也就是我們判斷「TalkBack 開著嗎」的依據。
  Future<void> pumpPage(
    WidgetTester tester, {
    required AuthService service,
    bool screenReaderOn = false,
    double textScale = 1.0,
    VoidCallback? onSkip,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(
            accessibleNavigation: screenReaderOn,
            textScaler: TextScaler.linear(textScale),
          ),
          child: AuthPage(
            service: service,
            speaker: speaker,
            onSkip: onSkip,
            haptic: () async => haptics++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('★ App 必須能單獨完整運作（不依賴螢幕閱讀器）', () {
    testWidgets('TalkBack 關著時，進入頁面會自己唸出說明', (tester) async {
      await pumpPage(tester, service: MockAuthService());
      expect(speaker.spoken, isNotEmpty, reason: '沒有螢幕閱讀器時，App 必須自己開口');
      expect(speaker.spoken.first.toLowerCase(), contains('sign in'));
    });

    testWidgets('TalkBack 關著時，成功登入會自己唸出結果', (tester) async {
      await pumpPage(tester, service: MockAuthService());
      speaker.spoken.clear();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(speaker.spoken, contains('Signing in'));
      expect(speaker.spoken, contains('Signed in'));
    });

    testWidgets('TalkBack 關著時，失敗也會自己唸出（不是靜默）', (tester) async {
      await pumpPage(tester, service: MockAuthService.offline());
      speaker.spoken.clear();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(speaker.spoken, contains('No network'));
    });

    testWidgets('TalkBack 開著時，App **不**出聲（避免與螢幕閱讀器疊在一起）',
        (tester) async {
      await pumpPage(tester,
          service: MockAuthService(), screenReaderOn: true);
      speaker.spoken.clear();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(speaker.spoken, isEmpty,
          reason: '兩邊都出聲比只有一邊更糟，所以開著時要完全退讓');
    });

    testWidgets('TalkBack 開著時，狀態變化仍然有 liveRegion 承接', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPage(tester,
          service: MockAuthService.offline(), screenReaderOn: true);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      // 狀態區必須存在且是 liveRegion，否則 TalkBack 開著時就真的沒有任何播報。
      expect(
        find.bySemanticsLabel(RegExp('Cannot reach the network')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('★ 防誤觸', () {
    testWidgets('忙碌中主按鈕被停用，第二次點擊不會再送出請求', (tester) async {
      final svc = MockAuthService.slow(const Duration(seconds: 2));
      await pumpPage(tester, service: svc);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pump(); // 不推進時間，讓請求停在半路

      final btn = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Sign in with Google'));
      expect(btn.onPressed, isNull, reason: '停用是唯一能真正防重複請求的做法');

      // 再點一次（即使按鈕已停用，直接呼叫也只是被守衛擋掉）
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'),
          warnIfMissed: false);
      await tester.pump();
      expect(svc.calls.where((c) => c == 'signIn').length, 1,
          reason: '不該送出第二次請求');

      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('忙碌中的按鈕帶有「已停用」語意，讓螢幕閱讀器能唸出來', (tester) async {
      final handle = tester.ensureSemantics();
      final svc = MockAuthService.slow(const Duration(seconds: 2));
      await pumpPage(tester, service: svc, screenReaderOn: true);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pump();

      // 實測到的節點：actions [focus]、flags [isButton, hasEnabledState, isFocusable]，
      // **沒有 isEnabled**。所以「停用」在這個 Flutter 版本的表示法是
      // 「有 hasEnabledState 但沒有 isEnabled」，螢幕閱讀器據此唸出「已停用」。
      expect(
        tester.getSemantics(
            find.widgetWithText(FilledButton, 'Sign in with Google')),
        matchesSemantics(
          label: 'Sign in with Google',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          hasFocusAction: true,
        ),
      );

      await tester.pumpAndSettle(const Duration(seconds: 3));
      handle.dispose();
    });

    testWidgets('★ 按下後**立刻**有回饋，不等網路', (tester) async {
      final svc = MockAuthService.slow(const Duration(seconds: 5));
      await pumpPage(tester, service: svc);
      speaker.spoken.clear();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pump(); // 只過一帧

      expect(speaker.spoken, contains('Signing in'),
          reason: '盲人按下去的第一個疑問是「按到了嗎」，不能等伺服器回答');
      expect(haptics, 1, reason: '觸覺是立即的，比語音更快回答「按到了」');

      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('TalkBack 開著時不自己震動（TalkBack 會給）', (tester) async {
      await pumpPage(tester,
          service: MockAuthService(), screenReaderOn: true);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(haptics, 0);
    });

    testWidgets('★ 首次查詢還沒回來時，畫面不能是空白的', (tester) async {
      // 這個測試來自一次真實的失敗：`MockAuthService.slow` 一開始把
      // `restore()`（本機查詢）也延遲了，於是頁面開頭有一段**完全空白、
      // 也沒有任何聲音**的時間。對盲人使用者那就是程式壞了。
      //
      // 修法有兩層：假貨的本機查詢不再延遲，而且頁面在查詢期間
      // 仍然顯示標題與一句載入提示（借狀態區顯示，於是它也是 liveRegion）。
      final svc = _SlowBootstrapService();
      await tester.pumpWidget(MaterialApp(
        home: AuthPage(service: svc, speaker: speaker),
      ));
      await tester.pump();

      expect(find.text('Sign in'), findsOneWidget, reason: '標題要立刻出現');
      expect(find.textContaining('Getting the sign in methods ready'),
          findsOneWidget, reason: '空白畫面沒有聲音等於沒有回饋');
      expect(find.byType(ButtonStyleButton), findsNothing,
          reason: '還不知道有哪些方式，就不該顯示任何方式');

      // 讓延遲到期，確認它會恢復成正常頁面（不是卡在載入狀態）。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Sign in with Google'),
          findsOneWidget);
    });

    testWidgets('進入頁面不自動聚焦輸入框（鍵盤不該自己彈出來）', (tester) async {
      await pumpPage(tester, service: MockAuthService());

      await tester.tap(find.text('Use email instead'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.autofocus, isFalse);
      expect(field.textInputAction, TextInputAction.next,
          reason: '打字時誤按 Enter 不該送出登入');
    });
  });

  group('簡潔與版面', () {
    testWidgets('可點元素 ≤ 5 個，且沒有破壞性動作', (tester) async {
      await pumpPage(tester, service: MockAuthService(), onSkip: () {});

      final count = tester.widgetList(find.byType(ButtonStyleButton)).length;
      expect(count, lessThanOrEqualTo(5), reason: '登入頁只有一個決定，選項不該再多');
      expect(find.text('Delete account'), findsNothing,
          reason: '登入頁完全沒有破壞性動作');
      expect(find.text('Sign out'), findsNothing);
    });

    testWidgets('不可用的方式不顯示按鈕（沒設指紋就不該出現指紋按鈕）', (tester) async {
      await pumpPage(tester, service: MockAuthService.biometricMissing());

      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text('Sign in with fingerprint'), findsNothing,
          reason: '顯示一個註定失敗的按鈕，對全盲使用者是純粹的陷阱');
    });

    testWidgets('標題是 heading（螢幕閱讀器可以跳過去）', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPage(tester, service: MockAuthService());

      expect(
        tester.getSemantics(find.text('Sign in')),
        matchesSemantics(label: 'Sign in', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('★ 系統字級 200% 不會溢出', (tester) async {
      await pumpPage(tester,
          service: MockAuthService(), textScale: 2.0, onSkip: () {});
      expect(tester.takeException(), isNull,
          reason: '排版必須在最大字級下仍然可用');
    });

    testWidgets('「稍後再說」與登入按鈕同級（同寬同高）', (tester) async {
      await pumpPage(tester, service: MockAuthService(), onSkip: () {});

      final google = tester.getSize(
          find.widgetWithText(FilledButton, 'Sign in with Google'));
      final skip =
          tester.getSize(find.widgetWithText(OutlinedButton, 'Not now'));
      expect(skip.width, google.width);
      expect(skip.height, google.height);
    });
  });

  group('狀態機', () {
    testWidgets('★ 取消不被當成錯誤', (tester) async {
      await pumpPage(tester, service: MockAuthService.cancelled());

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cancelled'), findsOneWidget);
      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
    });

    testWidgets('連不上時提供「重試」這個出口', (tester) async {
      await pumpPage(tester, service: MockAuthService.offline());

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      // 錯誤訊息裡必須講明下一步做什麼。
      expect(find.textContaining('Not now'), findsWidgets);
      expect(find.textContaining('Guidance still works'), findsOneWidget);
    });

    testWidgets('需要連結時彈出對話框，且**安全選項排在前面**', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPage(tester,
          service: MockAuthService.needsLinking('a@b.test'));

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(find.text('This email already has an account'), findsOneWidget);

      // 「不連結」必須排在「連結」之前（焦點順序 = widget 順序）。
      final keep = tester.getTopLeft(find.text('Do not link'));
      final link = tester.getTopLeft(find.text('Link'));
      expect(keep.dx, lessThan(link.dx),
          reason: '焦點從左往右走，安全的那個要在前面');
      handle.dispose();
    });

    testWidgets('登入成功後顯示帳號頁，且有破壞性動作', (tester) async {
      await pumpPage(tester, service: MockAuthService());

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text('Delete account'), findsOneWidget);
    });

    testWidgets('★ 登入成功會通知宿主回到引導（不是把使用者留在帳號頁）',
        (tester) async {
      // 這條來自一次真機回報：「登入成功後也沒有跳轉到應用」。
      // 使用者的目的是登入以便上傳，登入完就該回去。
      AuthAccount? reported;
      await tester.pumpWidget(MaterialApp(
        home: AuthPage(
          service: MockAuthService(),
          speaker: speaker,
          // ★ 一定要傳假的震動：不傳就會走真的 HapticFeedback 平台通道，
          //   而那個 future 在 widget 測試裡不會完成，`await _haptic()` 會卡住，
          //   於是後面所有事情都不會發生（症狀是「登入沒有成功」）。
          haptic: () async {},
          onSignedIn: (a) => reported = a,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(reported, isNotNull, reason: '不通知宿主就沒有跳轉');
      expect(reported!.email, isNotEmpty);
    });

    testWidgets('★ 帳號頁一定有「回到引導」這個出口', (tester) async {
      // 即使宿主沒提供任何 callback，也不能讓使用者進去出不來。
      await pumpPage(tester, service: MockAuthService());
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      expect(find.text('Back to guidance'), findsOneWidget);
    });

    testWidgets('「回到引導」會呼叫宿主提供的 callback', (tester) async {
      var left = 0;
      await tester.pumpWidget(MaterialApp(
        home: AuthPage(
          service: MockAuthService(),
          speaker: speaker,
          haptic: () async {},
          onBackToGuidance: () => left++,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Back to guidance'));
      await tester.pumpAndSettle();

      expect(left, 1);
    });

    testWidgets('刪除帳號的對話框用物件命名，不用「確定」', (tester) async {
      await pumpPage(tester, service: MockAuthService());
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();

      expect(find.text('Keep account'), findsOneWidget);
      expect(find.text('Delete account'), findsWidgets);
      expect(find.text('OK'), findsNothing);
      expect(find.text('Cancel'), findsNothing,
          reason: '只聽得到標籤時，「取消」不知道取消什麼');
    });
  });
}
