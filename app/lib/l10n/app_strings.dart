import 'app_locale.dart';
import '../vision/labels.dart';

/// All user-visible UI copy.
///
/// Two packs only: English (default / fallback) and Hong Kong Traditional
/// Chinese. System locales `zh*` / `yue` map to the Chinese pack; everything
/// else uses English. `supportedLocales` may list more variants so Material
/// widgets localize — that is not a third UI pack.
class AppStrings {
  const AppStrings._(this.language);

  final AppLanguage language;

  static AppStrings of(AppLanguage language) => AppStrings._(language);

  static AppStrings get current => AppStrings._(AppLocale.current);

  bool get _zh => language == AppLanguage.zh;

  String get appTitle => _zh ? '領路通' : 'PathGuide';

  String get initializing => _zh ? '正在初始化…' : 'Initializing…';

  String initializingSource(String name) =>
      _zh ? '正在初始化（$name）…' : 'Initializing ($name)…';

  String inferenceStreamError(Object e) =>
      _zh ? '推理流出錯：$e' : 'Inference stream error: $e';

  String get mockSelectCamera => _zh
      ? '模擬畫面：選擇「相機」以開始即時識別'
      : 'Mock view: select Camera to start live detection';

  String ttsFallbackWarning(String lang) => _zh
      ? '警告：未找到符合系統語言的語音包，目前使用 $lang'
      : 'Warning: no matching system voice found, using $lang';

  String get ttsNotReady => _zh ? '未就緒' : 'Not ready';

  String get fps => 'FPS';

  String get inference => _zh ? '推理' : 'Infer';

  String get boxes => _zh ? '檢測框' : 'Boxes';

  String get analyzedFrames => _zh ? '分析幀' : 'Analyzed';

  String get analyzeErrors => _zh ? '分析錯誤' : 'Analyze errors';

  String get scoreRange => _zh ? '分數' : 'Score';

  String get voice => _zh ? '語音' : 'Voice';

  String speakFloor(String value) => _zh
      ? '播報門檻 ≥ $value（低分只畫框）'
      : 'Speak floor ≥ $value (low scores draw only)';

  String get frame => _zh ? '幀' : 'Frame';

  String get rotation => _zh ? '旋轉' : 'Rotation';

  String get scale => 'scale';

  String get letterbox => _zh ? '留邊' : 'Pad';

  String get uncategorized => _zh ? '（未分類）' : '(uncategorized)';

  String get errorCopied => _zh ? '錯誤詳情已複製' : 'Error details copied';

  String sourceInitFailed(String name) => _zh
      ? '$name 初始化失敗（長按複製）'
      : '$name failed to start (long-press to copy)';

  String get sourceFallback => _zh ? '來源' : 'Source';

  String get displayThreshold => _zh ? '顯示閾值' : 'Display threshold';

  String get camera => _zh ? '相機' : 'Camera';

  String get mock => _zh ? '模擬' : 'Mock';

  String get iosDemo => _zh ? 'iOS 演示' : 'iOS demo';

  String get fakeData => _zh ? '假數據' : 'Fake data';

  String get muteSpeak => _zh ? '關閉播報' : 'Mute speech';

  String get unmuteSpeak => _zh ? '開啟播報' : 'Enable speech';

  String get speakEnabledProbe =>
      _zh ? '語音播報已開啟' : 'Voice announcements enabled';

  String get hideLabels => _zh ? '隱藏標籤' : 'Hide labels';

  String get showLabels => _zh ? '顯示標籤' : 'Show labels';

  String get startCapture => _zh ? '開始採集' : 'Start capture';

  String get stopCapture => _zh ? '停止採集' : 'Stop capture';

  String captureSavedCount(int count) =>
      _zh ? '已採集 $count 張' : 'Saved $count frames';

  String get captureNeedsCamera =>
      _zh ? '請先啟動相機再採集' : 'Start the camera before capturing';

  String get invalidDetections => _zh ? '無效' : 'Invalid';

  String get input => _zh ? '輸入' : 'Input';

  String get output => _zh ? '輸出' : 'Output';

  String geometryMismatch(int rawW, int rawH, int frameW, int frameH) => _zh
      ? '幾何不一致：畫框用 ${rawW}x$rawH，分析流實際 ${frameW}x$frameH → 框會整體偏移'
      : 'Geometry mismatch: overlay ${rawW}x$rawH vs analyze ${frameW}x$frameH';

  // --- Announcer decision reasons (UI log) ---

  String get reasonSkipPrefix => _zh ? '跳過：' : 'skip: ';

  String get reasonNormal => _zh ? '正常播報' : 'speak';

  String get reasonForced => _zh ? '強制播報' : 'forced speak';

  String scoreBelowFloor(String score, String floor) => _zh
      ? '分數 $score 低於播報門檻 $floor'
      : 'score $score below speak floor $floor';

  String get perClassCooldown => _zh ? '同類冷卻未過' : 'per-class cooldown';

  String get globalCooldown => _zh ? '全局冷卻未過' : 'global cooldown';

  bool reasonIsSkip(String reason) =>
      reason.startsWith(reasonSkipPrefix) ||
      reason.startsWith('跳過：') ||
      reason.startsWith('跳过：') ||
      reason.startsWith('skip: ');

  // --- Vision source names / status (must follow system language) ---

  String get sourceCamera => _zh ? '相機' : 'Camera';

  String get sourceMock => _zh ? '假數據' : 'Fake data';

  String get sourceWebCamera => _zh ? '瀏覽器相機' : 'Browser camera';

  String get mockModeReady => _zh
      ? '假數據模式：三個按已知規律運動的框，用於校驗座標映射'
      : 'Fake-data mode: three moving boxes for overlay checks';

  String get cameraNotStarted => _zh ? '相機未啟動' : 'Camera not started';

  String get cameraNotStartedDetail => _zh
      ? '模型已載入，但原生相機未啟動：可能未授予權限，或被其他程式佔用'
      : 'Model loaded, but the native camera did not start (permission or in use)';

  String get modelManifestBad => _zh ? '模型清單有問題' : 'Model manifest invalid';

  String get modelManifestMismatch => _zh ? '模型與清單不符' : 'Model/manifest mismatch';

  String modelManifestMismatchDetail({
    required int modelClassCount,
    required String version,
    required int declaredCount,
    required Object declaredIds,
  }) =>
      _zh
          ? '模型報告 $modelClassCount 類，而清單（$version）聲明 '
              'modelClassCount=$declaredCount、modelClassIds=$declaredIds。'
              '兩者必須一致——猜一個映射會把框標成別的類，而且不會報錯。'
          : 'Model reports $modelClassCount classes, but manifest ($version) declares '
              'modelClassCount=$declaredCount, modelClassIds=$declaredIds. '
              'They must match — guessing a mapping mislabels boxes silently.';

  String get modelNotLoaded => _zh ? '模型未載入' : 'Model not loaded';

  String modelLoaded({
    required int classCount,
    required Object inputSize,
    String mappingNote = '',
  }) =>
      _zh
          ? '模型已載入（類別數 $classCount，輸入 $inputSize）$mappingNote'
          : 'Model loaded ($classCount classes, input $inputSize)$mappingNote';

  String get webCameraNotStarted =>
      _zh ? '瀏覽器相機未啟動' : 'Browser camera not started';

  String get webCameraReady =>
      _zh ? '即時相機識別已啟動（TFLite）' : 'Live camera detection started (TFLite)';

  String get webCameraWebOnly =>
      _zh ? '瀏覽器相機僅支援 Web' : 'Browser camera is only available on Web';

  String get webCameraPreviewNotReady =>
      _zh ? '相機預覽尚未準備好，請重試' : 'Camera preview is not ready; try again';

  String get webCameraNeedsHttps => _zh
      ? '瀏覽器相機需要 HTTPS；請透過安全連線開啟此頁面'
      : 'Browser camera needs HTTPS; open this page over a secure connection';

  String webCameraStartFailed(Object error) =>
      _zh ? '啟動瀏覽器相機失敗：$error' : 'Failed to start browser camera: $error';

  // --- 產品畫面（單一畫面）---
  //
  // 這些是**使用者會聽到**的句子，所以每一條都要能只靠聽就懂。
  // 命名原則：標籤即結果，不用「開始」「確定」這類模糊詞
  //（見 docs/A11Y-ENTRY-AND-AUTH.md 的驗收清單）。

  /// 主按鈕：相機尚未就緒時。
  String get startGuidance => _zh ? '啟動引導' : 'Start guidance';

  /// 按下「啟動引導」之後的即時回饋。**先出聲再做事**——
  /// 這個專案把「按了之後沒反應」列為最嚴重的缺口。
  String get starting => _zh ? '正在啟動引導' : 'Starting guidance';

  /// 引導中，狀態列文字（也會被唸出來）。
  String get guiding => _zh ? '正在引導，前方有障礙物會出聲' : 'Guiding — obstacles will be announced';

  /// 引導已停止（回到未啟動狀態）。
  String get guidanceStopped => _zh ? '已停止引導' : 'Guidance stopped';

  /// 語音開關的標籤：label 是**動作 + 結果**，不是狀態。
  /// 螢幕閱讀器唸的是「要按下去會發生什麼」，不是「現在是什麼」。
  String get enableVoice => _zh ? '開啟語音' : 'Turn voice on';

  String get disableVoice => _zh ? '關閉語音' : 'Turn voice off';

  /// 停止引導。label 同樣是動作 + 結果。
  String get stopGuidance => _zh ? '結束引導' : 'End guidance';

  /// 點下語音開關後的確認（讓使用者知道按到了）。
  String get voiceOn => _zh ? '語音已開啟' : 'Voice on';

  String get voiceOff => _zh ? '語音已關閉' : 'Voice off';

  /// 讀到招牌時唸出的前置詞。**必須加**，否則使用者分不清
  /// 「前面有樓梯」（障礙物）與「麥當勞」（招牌）——兩者都是名詞。
  String get readSignPrefix => _zh ? '招牌寫著' : 'Sign reads';

  /// 出現率很低的事實陳述，用完整句避免被聽成指令。
  String get noCameraOnDevice => _zh
      ? '這台裝置沒有可用的相機，引導無法啟動'
      : 'No camera available on this device, so guidance cannot start';
}

/// Localized display / speak name for a detection label.
String labelDisplayName(Label label, [AppLanguage? language]) {
  final lang = language ?? AppLocale.current;
  return lang == AppLanguage.zh ? label.nameZh : label.nameEn.replaceAll('_', ' ');
}
