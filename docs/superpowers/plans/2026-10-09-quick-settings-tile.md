# 快速設定磁貼 + 語言啟動實測

日期：2026-10-09
相關：`docs/A11Y-ENTRY-AND-AUTH.md` 第 2 節（啟動路徑）

## 做了什麼

新增快速設定磁貼，讓領路通能從**通知欄**啟動，不必回主頁。
這是唯一「不需要回主頁、兩秒內可達」的路徑（見 `docs/A11Y-ENTRY-AND-AUTH.md` 第 2 節的路徑排序）。

新增／修改的檔案：

| 檔案 | 作用 |
|---|---|
| `app/android/app/src/main/kotlin/hk/pathguide/pathguide/PathGuideTileService.kt` | 磁貼服務 |
| `app/android/app/src/main/res/drawable/ic_qs_tile.xml` | 磁貼圖示 |
| `app/android/app/src/main/AndroidManifest.xml` | 宣告服務 |
| `app/android/app/src/main/res/values*/strings.xml` | 磁貼標籤（4 個語言） |

## 兩個技術要點（都是「寫錯不會報錯」的類型）

### 1. API 34 換了 `startActivityAndCollapse` 的簽名

`startActivityAndCollapse(Intent)` 在 API 34 起棄用，改用接受 `PendingIntent` 的多載版本。
本專案 targetSdk 是 36，所以兩條分支都要寫。用舊的會怎樣：**磁貼按了沒反應**，而且沒有錯誤訊息。

`PendingIntent` 一定要帶 `FLAG_IMMUTABLE`（API 31+ 的強制要求，缺了直接丟例外）。

### 2. manifest 三個屬性缺一不可

`permission`、`exported="true"`、`QS_TILE` intent-filter。
任何一個寫錯的結果都是「磁貼清單裡根本找不到它」，同樣不報錯。
所以 `tests/test_android_launch_contract.py` 把它們逐條釘死。

## 順手修好的門檻盲點：R 存根

寫磁貼時撞到 `unresolved reference 'R'`。查清楚後發現**那是 `check_kotlin_compiles.py` 的盲點，不是程式碼的錯**：
`R` 是 AGP 從資源生成的類別，單獨用 kotlinc 編譯時不存在。

**沒有**為了繞過門檻而拿掉程式碼裡的 icon/label。理由：那會讓磁貼行為依賴
「系統會用 manifest 的預設值」這個假設，而標籤正是全部的無障礙介面。
正確做法是讓門檻自己生成一份只含符號的 `R` 存根。

對以後的價值：**在這之前，任何正常引用 `R` 的 Android 程式碼都會被誤報。**
另外堵了一個假陽性陷阱：如果 `res/` 掃不到東西，存根會是空的，於是門檻會報出
一堆看起來像真錯的東西。現在會主動警告「這是門檻壞了，不是你的程式碼錯了」。

`tests/test_check_kotlin_compiles_r_stub.py` 有 10 條測試釘住它。

## 實測結果（真機 Xiaomi 2609FRA74T / Android 16 / arm64）

### 已完成的自動驗證

| 項目 | 證據 |
|---|---|
| APK 內確實有服務 | `aapt2 dump xmltree`：`name=...PathGuideTileService`、`permission=BIND_QUICK_SETTINGS_TILE`、`exported=true`、`action=QS_TILE` 四項齊全 |
| 各語言名稱已編入 | `application-label-zh-HK: 領路通`、`zh-CN: 领路通`、預設 `PathGuide` |
| 磁貼標籤各語言已編入 | `string/tile_label`：預設 `Start guidance`、`zh-HK/TW` `開始引導`、`zh-CN` `开始引导` |
| 系統把它當合法磁貼 | `dumpsys package` 出現 `filter ... permission BIND_QUICK_SETTINGS_TILE` |
| 已進入快速設定面板 | `settings get secure sysui_qs_tiles` 第一項就是 `custom(hk.pathguide.pathguide/.PathGuideTileService)` |
| **磁貼真的能冷啟動 App** | `force-stop` 之後用 `cmd statusbar click-tile`，`topResumedActivity` 變成 `MainActivity`，且 HUD 是**新的 pid** 在跑 |

> `cmd statusbar click-tile` 這台 ROM 有支援。**這是個很好用的驗證手段**：
> 不必猜座標、不必碰螢幕，就能確定性模擬點擊。以後驗證磁貼都該用它。
> 另外 `cmd statusbar add-tile` 可以直接把磁貼加進面板，不需要有人用手去拖，
> 這一點對「設定需要看得到的人幫忙」的問題是個實際的繞道。

### 還沒驗證

- **磁貼圖示的外觀**。目前模型不支援讀圖，我無法自己看截圖。
  截圖在 `artifacts/device/qs_panel2.png`，需要人眼確認圖示不是空白也不是變形。
  （圖示 path data 取自 Google Material Icons 官方 24px.svg，不是手寫，所以風險低，
  但風險低不等於驗證過。）
- **語音啟動**。這只能出聲講，見下節。

### 人眼驗證：通過

使用者回報「看到了」，磁貼在面板中可見。**A 的驗證到此完整**：
程式碼 → 門禁 → APK 內容 → 系統註冊 → 冷啓動 → 人眼可見，六段都過。

但過程中發現一件事，使用者一開始**沒看到磁貼**，原因是：

> **小米 HyperOS 的控制中心要從狀態列「右半邊」往下滑才會出現磁貼，
> 從左半或中間下滑只有通知、完全沒有磁貼。**

這件事已寫進 `docs/A11Y-ENTRY-AND-AUTH.md` 第 2.5 節，因為它不只是操作提示，
而是**推翻了那一節原本的說法**（原本寫「雙指下拉即可看到」）。

**設計上的意義**：「從右半邊下滑」是**位置手勢**。全盲使用者不知道手指落在哪一半，
也收不到「你滑錯邊」的提示，他只會聽到通知，然後以為這個功能不存在。
所以磁貼能不能算「兩秒內可達」，取決於有沒有**不依賴位置**的手勢
（待驗證：HyperOS 是否支援雙指下滑直接展開快速設定）。

**另一個坑**：`sysui_qs_tiles` 裡排第一位**不代表**畫面上第一格。
那份設定值只說明系統知道這個磁貼，排版由廠商 SystemUI 決定。
所以「好不好找」沒有任何設定值可以代替人眼看一次。

## 語音啟動的環境實測：Google 助理確實是預設

我原本擔心這台中國版小米 ROM 上「Google 助理」這個假設不成立，可能被小愛同學取代。
**實測推翻了我的擔心**：

| 項目 | 值 |
|---|---|
| `settings get secure assistant` | `com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService` |
| `settings get secure voice_interaction_service` | 同上 |
| `settings get secure voice_recognition_service` | `com.google.android.tts/…GoogleTTSRecognitionService` |
| `com.google.android.googlequicksearchbox` | **啟用** |
| `com.miui.voiceassist` | **不存在**（小愛同學沒裝） |

結論：**這台機器的預設助理是 Google 助理，語音啟動這條路存在**，
`docs/A11Y-ENTRY-AND-AUTH.md` 第 2.2 節的假設在**這台裝置上**成立。

⚠️ 但要注意這是一個裝置的結果，不是通則。中國大陸版小米通常預裝小愛同學而沒有
Google 服務。若目標使用者的手機是那種機器，「Ok Google」那條路可能根本不存在。
**在把語音當成主要啟動路徑之前，這件事要在目標機型上確認，不能從這一台推廣。**

### 另一個實測事實：手機語言是 zh-CN

`persist.sys.locale = zh-CN`、`settings get system system_locales = zh-CN`。

所以這台機器上現在看到的名稱與標籤都是**簡體**（`领路通`／`开始引导`），
而「英文系統下能不能用英文名字叫出 App」這個情境，**必須先把系統語言改成英文才能測**。
那正是這輪 label 本地化要修的情境。

### 一個我自己犯的錯，記在這裡

查助理時第一次的 PowerShell 輔助函式把
`System.Management.Automation.ErrorRecord` 打成了 `System.ManagementEvent.ErrorRecord`，
導致滿屏 TypeNotFound，而**判斷分支因此全部走錯**，輸出變成一整排「未安裝」。

而那個結論是**假的**：前一輪明明已經用 `pm list packages` 查到 Google app 有裝。

教訓：**包裝 adb 輸出的輔助函式一旦壞掉，錯誤會表現成「查不到／未安裝」，
而不是報錯。** 這種形狀的錯誤比當掉更危險，因為它會產生看起來很確定的假事實。
（本倉庫在 `verify_on_device.ps1` 裡也記過同類問題：adb 把提示寫進 stderr，
PowerShell 會包成 ErrorRecord 污染解析。）

## 下一步

1. **人眼確認圖示**（看 `artifacts/device/qs_panel2.png` 或直接看手機的通知欄）。
2. **把系統語言改成英文**，確認三件事：桌面圖示唸 `PathGuide`、
   磁貼標籤變 `Start guidance`、App 介面變英文。
3. **測語音啟動**：分別試 Google 助理與小愛同學，看哪個會真的開啟 App。
   若兩者都不行，那 `docs/A11Y-ENTRY-AND-AUTH.md` 第 2 節的路徑排序要重寫。
4. 修正 `docs/A11Y-ENTRY-AND-AUTH.md` 第 2.2 節：把「Google 助理」改成
   「系統預設助理（可能是 Google 或廠商自己的）」，並記錄實測結果。

## 未做的部分

- 藍芽遙控按鍵（路徑 3）：`docs/A11Y-ENTRY-AND-AUTH.md` 第 2.4 節有設計，
  但需要實體硬體才能驗證。
- App Actions（路徑 2 進階）：需要先上架 Play，畢設階段不做。
