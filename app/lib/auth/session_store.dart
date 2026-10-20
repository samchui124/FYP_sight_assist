/// 「記住我」的儲存介面。
///
/// ## 為什麼要切一個介面出來，而不是直接用某個套件
///
/// 把帳號寫到磁碟需要一個儲存套件，但**那個套件現在還不能選**：
/// `app/pubspec.yaml` 記著一條硬約束 —— 本倉庫路徑含空格，任何拉進
/// `objective_c` 的依賴都會讓建構失敗，而這只能用真的一次建構來驗證。
///
/// 切出這個介面之後：畫面與測試現在就能全部做完，真正的磁碟版之後補
/// （大約 15 行），而且換的時候不會動到任何畫面或測試。
///
/// 這與 `app/lib/vision/` 的做法一致：介面在這裡，實作可替換。
library;

import 'auth_service.dart';

abstract interface class SessionStore {
  /// 讀回上次登入的帳號；沒有就回 null。
  Future<AuthAccount?> read();

  /// 寫入帳號；傳 null 表示清除（登出）。
  Future<void> write(AuthAccount? account);
}

/// 記憶體版：App 一關就忘。
///
/// stub 階段用這個。它的價值是讓「預設保持登入」這個行為**可以測**，
/// 而不是等到真的有磁碟儲存才能驗證。
final class InMemorySessionStore implements SessionStore {
  InMemorySessionStore([this._account]);

  AuthAccount? _account;

  /// 測試用：目前存了什麼。
  AuthAccount? get peek => _account;

  @override
  Future<AuthAccount?> read() async => _account;

  @override
  Future<void> write(AuthAccount? account) async => _account = account;
}
