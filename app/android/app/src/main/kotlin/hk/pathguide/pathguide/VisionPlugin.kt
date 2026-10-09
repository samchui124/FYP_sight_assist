package hk.pathguide.pathguide

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.util.Log
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
// OCR（識字）。★ 用 `com.google.mlkit:`（綁定版）——模型包在 APK 裡，離線可用。
// 見 build.gradle.kts 的說明：`play-services-` 那條會走 Play Services 按需下載。
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.tensorflow.lite.Interpreter
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * Android 侧视觉插件：CameraX 取帧 + LiteRT 推理 + 平台通道回传。
 *
 * ## 为什么推理放在原生侧
 *
 * `ImageProxy.planes[0]` 是 Y（亮度）平面的**直接内存映射**，原生侧零拷贝可读。
 * 若把整帧 `w*h*1.5` 字节经平台通道搬到 Dart，每帧要多一次跨语言拷贝，
 * 且 Dart 里没有硬件加速的 YUV→RGB。所以取帧、旋转、letterbox、推理、NMS
 * **全在 Kotlin**，只有归一化后的框过通道。
 *
 * ## 与 Dart 的契约
 *
 * 键名全部来自 `lib/vision/platform_contract.dart`，本文件不得自行发明字符串。
 *
 * - `hk.pathguide/vision`         MethodChannel：loadModel / detect / release / status
 * - `hk.pathguide/vision/frame`   EventChannel：逐帧推检测结果
 * - `hk.pathguide/vision/preview` 平台视图：相机预览
 */
class VisionPlugin(
    private val context: Context,
) : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val TAG = "PathGuideVision"
        const val METHOD_CHANNEL = "hk.pathguide/vision"
        const val FRAME_CHANNEL = "hk.pathguide/vision/frame"
        const val PREVIEW_VIEW = "hk.pathguide/vision/preview"

        /**
         * 历史常量：早期版本从 AssetManager 读模型用的路径。
         *
         * **已不再使用**，保留仅为记录这段经历，避免以后有人再走同一条路：
         * 真机（Redmi / Android 16 / HyperOS）上 `AssetManager.open()` 读
         * `flutter_assets/assets/models/detector.tflite` 必然 FileNotFoundException，
         * 而同一次运行里 `assets.list()` 递归又能列出这个路径——ROM 行为与
         * Android 文档约定不符，改路径试了三轮都无效。
         *
         * 现在模型由 Dart 侧用 rootBundle 读出、写入应用私有目录（见 modelDir /
         * writeFile 两个方法），Kotlin 只读文件，彻底绕开 AssetManager。
         */
        @Suppress("unused")
        const val LEGACY_MODEL_ASSET = "flutter_assets/assets/models/detector.tflite"

        /** 期望输入边长；模型若声明了固定形状则以模型为准。 */
        const val EXPECTED_INPUT_SIZE = 640

        /** 相机权限请求码。 */
        private const val REQ_CAMERA = 7301
    }

    private var methodChannel: MethodChannel? = null
    private var frameChannel: EventChannel? = null

    /** 当前 Activity。权限请求需要它，由 ActivityAware 回调注入。 */
    private var activity: android.app.Activity? = null

    /** 等待权限结果的 startPreview 调用。同一时刻只允许一个。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    @Volatile private var eventSink: EventChannel.EventSink? = null

    @Volatile var detector: YoloDetector? = null
        private set

    /** 实际加载成功的模型路径。报给 Dart 的是**真实发生过的事**，不是猜的常量。 */
    @Volatile var loadedModelPath: String? = null
        private set

    @Volatile var currentPreview: PreviewView? = null
        private set

    @Volatile var threshold: Float = 0.30f

    // ---- 诊断计数器：全部随每帧结果回传，直接显示在 HUD 上 ----
    // 加的动机：曾出现「预览正常、但推理 0 次」的情况，而当时**拿不到任何计数**，
    // 只能靠反复重新构建来猜。这类问题必须能让用户在屏幕上自己看到。
    @Volatile var analyzedFrames: Long = 0
        private set
    @Volatile var analyzeErrors: Long = 0
        private set

    /** 最近一帧被跳过的原因（空串表示正常处理）。 */
    @Volatile var lastAnalyzeSkip: String = "尚未收到任何帧"
        private set

    /**
     * 最近一次分析异常的类型与消息。
     *
     * 与 [lastAnalyzeSkip] 分开保存是刻意的：曾把两者混用，导致错误信息被下一帧
     * 的清空逻辑覆盖，用户永远看不到原因——真机上就是这样丢掉线索的。
     * 这个字段**只在成功分析的帧里清除**。
     */
    @Volatile var lastAnalyzeError: String = ""
        private set

    @Volatile var lastFrameWidth: Int = 0
        private set
    @Volatile var lastFrameHeight: Int = 0
        private set

    /** 最近一帧的格式描述（平面数、旋转角、UV 步长），用于核对取帧假设。 */
    @Volatile var lastFrameFormat: String = ""
        private set

    /** 最近一帧的最高置信度（**不受阈值影响**），用于判断「模型有没有给出高分」。 */
    @Volatile var lastMaxScore: Float = 0f
        private set

    /** 最近一帧的最低置信度。与 max 一起显示成 `min~max`，一眼能看出范围是否正常。 */
    @Volatile var lastMinScore: Float = 0f
        private set

    /** 最近一帧的检测数（经阈值与无效值过滤后）。 */
    @Volatile var lastDetectionCount: Int = 0
        private set

    /**
     * 最近一帧相机平面的紧凑拷贝，供定时采集写成 JPEG。
     * 不能持有 [ImageProxy]——analyze 结束后会被 close。
     */
    @Volatile private var lastCapture: LastCaptureFrame? = null

    private var cameraExecutor: ExecutorService? = null

    /**
     * OCR 專用執行緒。**刻意與 [cameraExecutor] 分開。**
     *
     * ## 為什麼不能共用
     *
     * 相機的分析執行緒是**單執行緒**，而且 `ImageAnalysis` 的背壓策略是
     * `STRATEGY_KEEP_ONLY_LATEST`：它只投遞最新一帧，前一帧還沒處理完就直接丟掉。
     *
     * 如果 OCR（真機預估 200–400 ms）跑在那條執行緒上：
     * - OCR 期間完全沒有帧被分析 → 引導畫面**明顯卡住**
     * - 而且那條執行緒被佔用時，`analyze()` 來不及消費帧，
     *   後續帧會被 KEEP_ONLY_LATEST 丟棄 → **測出來的 FPS 掉幅是假的**
     *
     * 而「OCR 期間引導掉多少 FPS」正是這個 spike 唯一要回答的問題。
     * 用會自己製造停頓的方式去量它，等於量到自己的測量工具。
     *
     * 分開之後，OCR 與偵測是**兩條執行緒在搶同一顆 CPU**——
     * 那才是真機上真正會發生的競爭，也是唯一值得量測的數字。
     *
     * 生命週期比相機長：OCR 是按需、可獨立於預覽存在的動作。
     */
    private var ocrExecutor: ExecutorService? = null

    private data class LastCaptureFrame(
        val y: ByteArray,
        val u: ByteArray,
        val v: ByteArray,
        val width: Int,
        val height: Int,
        val chromaWidth: Int,
        val rotationDegrees: Int,
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger: BinaryMessenger = binding.binaryMessenger
        // OCR 執行緒在此建立、在 onDetachedFromEngine 關閉。生命週期跟引擎一致，
        // 而不是跟相機一致——見 ocrExecutor 的說明。
        ocrExecutor = Executors.newSingleThreadExecutor()
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(::onMethodCall)
        }
        frameChannel = EventChannel(messenger, FRAME_CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
        binding.platformViewRegistry.registerViewFactory(
            PREVIEW_VIEW,
            VisionPreviewFactory(context, this),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        frameChannel?.setStreamHandler(null)
        methodChannel = null
        frameChannel = null
        eventSink = null
        stopCamera()
        ocrExecutor?.shutdown()
        ocrExecutor = null
        detector?.close()
        detector = null
    }

    // ------------------------------------------------------------------ 方法

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadModel" -> result.success(loadModel(call))
            "detect" -> result.success(detect(call))
            "setThreshold" -> {
                val v = call.argument<Double>("threshold")
                if (v == null) {
                    result.error("bad_args", "缺少 threshold", null)
                } else {
                    threshold = v.toFloat().coerceIn(0f, 1f)
                    Log.i(TAG, "阈值更新为 ${threshold}")
                    result.success(null)
                }
            }
            // Dart 侧请求启动相机。**这里同时负责申请权限**：
            // 权限是运行时申请的，若只在插件构造时检查一次，用户授权后
            // 原生侧仍停留在「无权限」，相机永不启动，表现为一片黑且无报错。
            //
            // 刻意不用 permission_handler 包：它会传递引入 objective_c，
            // 后者的 build hook 在含空格的路径上会让 `flutter test` 失败。
            // 见 pubspec.yaml 里的说明。
            "startPreview" -> requestPermissionThenStart(result)

            // ---- 模型落盘支持 ----
            // 实测某些 ROM 上 AssetManager 读不到 flutter_assets 下的资源，
            // 因此改为 Dart 用 rootBundle 读出、写到这里、原生再读文件。
            "modelDir" -> result.success(context.filesDir.absolutePath)

            "writeFile" -> {
                val path = call.argument<String>("path")
                val bytes = call.argument<ByteArray>("bytes")
                if (path == null || bytes == null) {
                    result.error("bad_args", "缺少 path 或 bytes", null)
                } else {
                    runCatching {
                        val f = java.io.File(path)
                        f.parentFile?.mkdirs()
                        f.writeBytes(bytes)
                    }.onSuccess {
                        Log.i(TAG, "已写入 ${bytes.size / 1024} KB -> $path")
                        result.success(null)
                    }.onFailure {
                        Log.e(TAG, "写入失败：$path", it)
                        result.error("write_failed", "${it.javaClass.simpleName}: ${it.message}", null)
                    }
                }
            }

            "fileSize" -> {
                val path = call.argument<String>("path")
                val f = if (path == null) null else java.io.File(path)
                result.success(if (f != null && f.exists()) f.length() else -1L)
            }
            "release" -> {
                stopCamera()
                detector?.close()
                detector = null
                result.success(null)
            }
            "status" -> result.success(
                mapOf(
                    "ready" to (detector != null),
                    // 报实际加载成功的那个路径，不是猜的常量。
                    "modelPath" to loadedModelPath,
                    "inputSize" to (detector?.inputSize ?: EXPECTED_INPUT_SIZE),
                    "classes" to (detector?.numClasses ?: 0),
                    // 诊断计数：让 Dart 能在界面上显示「分析了几帧、为什么跳过」。
                    // 这些信息以前只能通过 logcat 看，而用户手上没有 logcat。
                    "analyzedFrames" to analyzedFrames,
                    "analyzeErrors" to analyzeErrors,
                    "skippedReason" to lastAnalyzeSkip,
                    "analyzeError" to lastAnalyzeError,
                    "frameWidth" to lastFrameWidth,
                    "frameHeight" to lastFrameHeight,
                    "frameFormat" to lastFrameFormat,
                    "frameMaxScore" to lastMaxScore.toDouble(),
                    "frameMinScore" to lastMinScore.toDouble(),
                    "detectionCount" to lastDetectionCount,
                    "invalidDetections" to (detector?.invalidCount ?: 0L),
                    "invalidSample" to (detector?.firstInvalidSample ?: ""),
                    "invalidByReason" to (detector?.invalidByReason?.toMap() ?: emptyMap<String, Long>()),
                    "inputStats" to (detector?.inputStats ?: ""),
                    "outputStats" to (detector?.outputStats ?: ""),
                    "decodeStats" to (detector?.decodeStats ?: ""),
                    "bufferState" to (detector?.bufferState ?: ""),
                    "threshold" to threshold.toDouble(),
                    "anchors" to (detector?.anchorCount ?: 0),
                    "channels" to (detector?.channelCount ?: 0),
                    "transposed" to (detector?.isTransposed ?: false),
                ),
            )
            "captureFrame" -> {
                // JPEG 编码放后台，避免卡住平台通道回调线程。
                runOffMainThread { result.success(saveLastCaptureJpeg()) }
            }

            // OCR：讀最近一幀的招牌／門牌／指示牌文字。**按需呼叫**，不常駐。
            "readText" -> runOffMainThread { result.success(readLastCaptureText()) }

            // 診斷用：對**指定圖片檔**跑 OCR，可指定長邊上限與辨識器語系。
            //
            // 為什麼需要它：真機上「讀到亂碼」「英文被逐字母唸」這兩件事
            // 只有在**真實招牌**上才看得出來，而機會式排程每 1.5–12 秒才跑一次、
            // 還受「場景未變」影響，根本沒法穩定重現。
            // 這個入口讓同一張圖可以用不同解析度／辨識器各跑一遍做對照，
            // 是「憑感覺調參數」與「有數字」之間的差別。
            "ocrFile" -> runOffMainThread { result.success(ocrFileCall(call)) }

            else -> result.notImplemented()
        }
    }

    /**
     * 加载模型，返回 `{loaded, classes, inputSize}`（失败时附 `error`）。
     *
     * 模型缺失时**不抛异常**：demo 在没有模型时仍要能跑界面（配假数据源），
     * 抛异常会让画面白屏，反而看不出问题出在哪。
     *
     * 入参 `model` 是**绝对文件路径**（由 Dart 侧用 rootBundle 把资源落盘得到）。
     * 不再依赖 AssetManager —— 实测在某些 ROM 上 `AssetManager.open()` 读
     * `flutter_assets/...` 必然 FileNotFoundException，而同一次运行里
     * `assets.list()` 又能列出该路径，即 ROM 行为与文档约定不符。
     */
    private fun loadModel(call: MethodCall): Map<String, Any?> {
        val path = call.argument<String>("model")
        // ★ 类别索引映射表：**下标 = 模型本地索引，值 = 项目类别表里的真实 id**。
        //
        // 模型内部只能说 0..nc-1（YOLO 的标签契约），而项目类别表里
        // 0 是 footbridge_entrance。不映射就会把垃圾桶标成「天橋入口」——
        // **框对、名字错、不报错**，这是本项目最该防的一类故障。
        //
        // 早先只有一个类时用「加一个常数偏移」，3 类以上表达不了，改成映射表。
        // 空表 = 不需要映射（模型类别数已等于项目类别表，输出即真实 id）。
        val classIds = call.argument<List<Int>>("classIds") ?: emptyList()
        detector?.close()
        detector = null
        loadedModelPath = null

        if (path.isNullOrBlank()) {
            return mapOf(
                "loaded" to false, "classes" to 0, "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "Dart 侧没有给出模型文件路径（model 参数为空）",
            )
        }
        val f = java.io.File(path)
        if (!f.exists()) {
            val dir = f.parentFile
            val siblings = dir?.listFiles()?.joinToString(", ") { it.name } ?: "（目录不存在）"
            return mapOf(
                "loaded" to false, "classes" to 0, "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "文件不存在：$path（同目录下有：$siblings）",
            )
        }

        return try {
            // ★ LiteRT 不接受堆缓冲 `ByteBuffer.wrap(byte[])`，会抛
            //     IllegalArgumentException: Model ByteBuffer should be either a
            //     MappedByteBuffer of the model file, or a direct ByteBuffer using
            //     ByteOrder.nativeOrder()
            // 所以用**文件内存映射**：既满足要求，又省掉一次 10 MB 的内存拷贝。
            // 这也正是当初该直接用文件路径、而不是先在 Dart 侧读成字节的原因之一。
            val det = YoloDetector.fromFile(f, EXPECTED_INPUT_SIZE)
            // ★ 校验映射表与模型类别数是否相符。**不符就拒绝加载，不猜。**
            //
            // 猜错的映射不会崩：它只会让每个框的名字是另一个类。这类错误在
            // 演示里看着「框都画出来了」，在训练里看着「指标还行」，
            // 所以必须在这里挡住。三种合法情形：
            //   - 空表      -> 不需要映射（模型类别数 == 项目类别数）
            //   - 长度相符  -> 按表映射
            //   - 其他      -> 报错
            val appliedIds: List<Int> = when {
                classIds.isEmpty() -> emptyList()
                classIds.size == det.numClasses -> classIds
                else -> {
                    Log.w(
                        TAG,
                        "映射表长度 ${classIds.size} 与模型类别数 ${det.numClasses} 不符，拒绝加载",
                    )
                    return mapOf(
                        "loaded" to false, "classes" to det.numClasses,
                        "inputSize" to EXPECTED_INPUT_SIZE,
                        "error" to "类别映射表有 ${classIds.size} 项，模型有 ${det.numClasses} 类：" +
                            "两者必须一致。不一致时猜一个映射会把框标成别的类且不报错，故拒绝加载。",
                    )
                }
            }
            det.classIds = appliedIds
            detector = det
            loadedModelPath = path
            startCameraIfPossible()
            Log.i(
                TAG,
                "模型已加载：$path（${f.length() / 1024} KB, ${det.numClasses} 类, " +
                    "映射 ${if (appliedIds.isEmpty()) "无（输出即真实 id）" else appliedIds.toString()}）",
            )
            mapOf(
                "loaded" to true,
                "classes" to det.numClasses,
                "inputSize" to det.inputSize,
                "modelPath" to path,
                "classIds" to appliedIds,
            )
        } catch (e: Exception) {
            Log.w(TAG, "模型加载失败：$path", e)
            mapOf(
                "loaded" to false, "classes" to 0, "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "读文件/建解释器失败 ${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    /**
     * 单帧推理（回放 / 调试路径）。实时相机路径不走这里，走 EventChannel，
     * 省掉一次整帧跨通道拷贝。
     *
     * ## 需要完整的 YUV，不能只给 Y
     *
     * 模型要 RGB 输入。只给 Y 平面时这里用 U=V=128（中性灰）补齐，
     * 结果是**灰度**输入——实测置信度会掉到阈值以下，等于检测不到。
     * 所以调用方应当通过 `u` / `v` 传真实色度；只有明确知道不需要颜色时
     * 才省略它们（例如把检测当作纯几何验证）。
     *
     * 这条限制是真机上踩出来的：早期版本只传 Y，24 类模型在真机上一个框都不出，
     * 排查了很久才定位到颜色空间不匹配。
     */
    private fun detect(call: MethodCall): Map<String, Any?> {
        val det = detector
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "模型未加载")
        val y = call.argument<ByteArray>("bytes")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 bytes（Y 平面）")
        val w = call.argument<Int>("frameWidth")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 frameWidth")
        val h = call.argument<Int>("frameHeight")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 frameHeight")
        val rotation = call.argument<Int>("rotationDegrees") ?: 0
        val thr = (call.argument<Double>("threshold") ?: threshold.toDouble()).toFloat()

        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val uBytes = call.argument<ByteArray>("u")
        val vBytes = call.argument<ByteArray>("v")
        val u = if (uBytes != null && uBytes.size >= cw * ch) uBytes
                else ByteArray(cw * ch) { 128.toByte() }
        val v = if (vBytes != null && vBytes.size >= cw * ch) vBytes
                else ByteArray(cw * ch) { 128.toByte() }

        // 传**紧凑副本宽度 cw**，不是原始平面的 rowStride/pixelStride：
        // 这里收到的 u/v 就是按 cw*ch 紧凑排列的（上面的长度检查也按它做）。
        // 相机那条路径曾经传的是原始平面步长，导致色度取错、画面变灰。
        val dets = det.detectYuv(
            y, u, v, w, h,
            cw,
            rotationDegrees = rotation, threshold = thr,
        )
        return mapOf(
            "detections" to dets.map { it.toMap() },
            "inferenceMs" to det.lastInferenceMs,
        )
    }

    // ------------------------------------------------------------------ 相机

    // -------------------------------------------------------------- 权限

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /**
     * 申请相机权限，拿到结果后启动相机，并把结果回给 Dart。
     *
     * 回包 `{started, granted}`：`granted=false` 表示用户拒绝，
     * Dart 侧要给出可操作的提示，而不是静默黑屏。
     */
    private fun requestPermissionThenStart(result: MethodChannel.Result) {
        if (hasCameraPermission()) {
            startCameraIfPossible()
            result.success(mapOf("started" to true, "granted" to true))
            return
        }
        val act = activity ?: run {
            Log.w(TAG, "没有 Activity，无法申请权限")
            result.success(mapOf("started" to false, "granted" to false))
            return
        }
        if (pendingPermissionResult != null) {
            // 前一次请求还没回来。直接失败而不是覆盖，避免结果丢失。
            result.error("busy", "上一次权限请求尚未返回", null)
            return
        }
        pendingPermissionResult = result
        act.requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQ_CAMERA)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_CAMERA) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        if (granted) {
            startCameraIfPossible()
            pending?.success(mapOf("started" to true, "granted" to true))
        } else {
            Log.w(TAG, "用户拒绝了相机权限")
            pending?.success(mapOf("started" to false, "granted" to false))
        }
        return true
    }

    // ------------------------------------------------- ActivityAware 回调

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        failPendingPermission("Activity 正在重建")
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        failPendingPermission("Activity 已分离")
        activity = null
    }

    /** 权限回调永远不会来了（Activity 销毁/重建）时必须给 Dart 一个结果，
     *  否则 startPreview 的 Future 永不完成，界面上表现为卡在「正在初始化」。 */
    private fun failPendingPermission(reason: String) {
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        pending.success(mapOf("started" to false, "granted" to false, "reason" to reason))
    }

    fun onPreviewCreated(view: PreviewView) {
        currentPreview = view
        startCameraIfPossible()
    }

    fun startCameraIfPossible() {
        // ★ 这里有**两个**前置条件，而且它们的就绪顺序不确定：
        //   - `detector != null`：模型由 Dart 侧异步落盘后再加载
        //   - `currentPreview != null`：预览平台视图由 widget 树建立
        // 任何一方先到都只是「还不行」，**不当成错误**——真正的启动发生在
        // 两者都就绪的那一次调用（三条路径都会调它：模型加载完、权限回调、
        // 预览建立）。真机实测日志里可以看到它被调用 4 次，最后一次才成功启动。
        //
        // 这段诊断保留：它一眼就能区分「模型没就绪」「预览没就绪」「权限被拒」
        // 三种都表现为「一片黑」的原因，而那是本项目花过很多轮才查清的一类故障。
        val view = currentPreview
        Log.i(
            TAG,
            "startCameraIfPossible: preview=${view != null} " +
                "detector=${detector != null} perm=${hasCameraPermission()}",
        )
        if (view == null) return
        if (detector == null) return
        // 每次**动态**检查权限。缓存这个结果会导致：用户在 Dart 侧授权之后，
        // 原生侧仍认为无权限，相机永远不启动，屏幕上只有一片黑、也没有异常。
        if (!hasCameraPermission()) {
            Log.w(TAG, "尚未授予相机权限，预览不启动；授权后请调用 startPreview")
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            runCatching { bindCamera(future.get(), view) }
                .onFailure { Log.e(TAG, "绑定相机会话失败", it) }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bindCamera(provider: ProcessCameraProvider, view: PreviewView) {
        // 必须用 ActivityAware 注入的 activity，**不能用插件构造时的 context**：
        // Flutter 传给插件的 context 是 Activity 的包装上下文，
        // (context as? LifecycleOwner) 永远为 null，相机就永远绑不上——
        // 表现为预览一片黑，日志里只有一行「不是 LifecycleOwner」。
        val owner = activity as? LifecycleOwner
        if (owner == null) {
            Log.e(TAG, "activity 不是 LifecycleOwner，无法绑定相机生命周期")
            return
        }
        val previewUseCase = Preview.Builder().build().also {
            it.surfaceProvider = view.surfaceProvider
        }
        // ★ 明確提高分析流解析度，因為 **OCR 吃的是這一條流的影格**。
        //
        // `lastCapture`（供 OCR 用）就是從 `analyze()` 裡存下來的，所以
        // 「OCR 讀得多好」直接由**這裡**決定。不指定時 CameraX 預設給
        // 640×480，實測 OCR 只有 480x640，於是：
        //
        //   - 字太小／太遠 → ML Kit 把雜訊拼成假字串
        //     （真機實際讀到 `"i08eeoaia。.g"`、`"d0那Mele l)"`）
        //   - 這些碎片被當成招牌唸出來，比不出聲更糟
        //
        // ## 為什麼不是「縮放解析度」
        //
        // 先前的變因量測顯示「把乾淨大圖縮到 320 vs 1280」對 OCR 幾乎沒差——
        // 但那證明的是**縮放**不影響，不是**取像**不影響。
        // 真正的差別在感光元件取到多少細節。這是兩件不同的事，
        // 我先前混為一談，結論錯了。
        //
        // ## 成本
        //
        // 偵測器拿到更大的幀，逐像素前處理會變貴，所以 FPS 一定會掉。
        // 真機實測（640×480 → 1280×720）之前是 4.86 FPS，
        // 提高之後必須重新量，掉了多少要寫在回報裡，不能假設。
        val analysisResolution = ResolutionSelector.Builder()
            .setAspectRatioStrategy(
                AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY,
            )
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(1280, 960),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                ),
            )
            .build()
        val executor = cameraExecutor
            ?: Executors.newSingleThreadExecutor().also { cameraExecutor = it }
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(analysisResolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { it.setAnalyzer(executor) { proxy -> analyze(proxy) } }

        provider.unbindAll()
        provider.bindToLifecycle(
            owner, CameraSelector.DEFAULT_BACK_CAMERA, previewUseCase, analysis,
        )
        Log.i(TAG, "相机会话已启动（预览 + 分析）")
    }

    fun stopCamera() {
        runCatching {
            ProcessCameraProvider.getInstance(context).get().unbindAll()
        }.onFailure { Log.w(TAG, "解绑相机失败（通常可忽略）", it) }
        cameraExecutor?.shutdown()
        cameraExecutor = null
        currentPreview = null
        lastCapture = null
        // 停止后重置诊断计数，避免「上一轮运行的帧数」被误读成当前状态。
        analyzedFrames = 0
        analyzeErrors = 0
        lastAnalyzeSkip = "相机已停止"
        lastFrameFormat = ""
        lastMaxScore = 0f
    }

    /**
     * 把 [lastCapture] 写成应用私有目录 captures/ 下的 JPEG。
     * 坐标系按传感器旋转纠正为正立，便于后期标注。
     */
    private fun saveLastCaptureJpeg(): Map<String, Any?> {
        val snap = lastCapture
            ?: return mapOf("ok" to false, "error" to "尚無相機幀")
        return runCatching {
            val nv21 = yuvPlanesToNv21(
                snap.y, snap.u, snap.v, snap.width, snap.height, snap.chromaWidth,
            )
            val yuv = YuvImage(nv21, ImageFormat.NV21, snap.width, snap.height, null)
            val rawJpeg = ByteArrayOutputStream().use { out ->
                if (!yuv.compressToJpeg(Rect(0, 0, snap.width, snap.height), 85, out)) {
                    error("JPEG 壓縮失敗")
                }
                out.toByteArray()
            }
            val (jpeg, outW, outH) = rotateJpegIfNeeded(
                rawJpeg, snap.width, snap.height, snap.rotationDegrees,
            )
            val dir = File(context.filesDir, "captures").apply { mkdirs() }
            val name = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US)
                .format(Date()) + ".jpg"
            val file = File(dir, name)
            file.writeBytes(jpeg)
            Log.i(TAG, "已採集 ${jpeg.size / 1024} KB -> ${file.absolutePath}")
            mapOf(
                "ok" to true,
                "path" to file.absolutePath,
                "width" to outW,
                "height" to outH,
                "bytes" to file.length(),
            )
        }.getOrElse { e ->
            Log.e(TAG, "captureFrame 失敗", e)
            mapOf(
                "ok" to false,
                "error" to "${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    /**
     * 把这个 method channel 调用丢到后台线程，回包再切回主线程。
     *
     * 为什么必须这样：JPEG 编码與 OCR 都是**百毫秒级**的同步工作。若在
     * method channel 的回调线程上直接做完，那个线程正好也在处理逐帧
     * EventChannel 的投递，会造成掉帧——看起来像「推理变慢了」，其實是
     * 回包线程被占用。
     *
     * ## 用哪條執行緒，取決於工作是什麼
     *
     * - [ocrExecutor]：OCR 與採集。**這兩件都是數百毫秒的長工作**，
     *   而且 OCR 要量的正是「與偵測搶 CPU」的代價，所以必須與相機分開。
     * - [cameraExecutor]：只有在 OCR 執行緒還沒建立時（理論上不會發生）才退而求其次。
     *
     * ★ 兩者都不在時自建一個**臨時**執行緒，做完即關——但那是最後手段，
     *   因為每次呼叫都建執行緒本身就是額外成本。
     *
     * ★ 注意：**不要**把這裡改成直接 `executor.execute` 而不保留 finally。
     *   工作若拋出例外，`result` 就永遠不回包，Dart 側的 `await` 會**永久懸住**
     *   （不是拋錯、不是逾時，就是永遠等不到）。所以 work() 內部自己 try/catch，
     *   這裡再包一層 finally 保證執行緒回收。
     */
    private fun runOffMainThread(work: () -> Unit) {
        val shared = ocrExecutor ?: cameraExecutor
        val executor = shared ?: Executors.newSingleThreadExecutor()
        executor.execute {
            try {
                work()
            } finally {
                if (shared == null) {
                    executor.shutdown()
                }
            }
        }
    }

    /**
     * OCR：讀 [lastCapture] 那一幀上面的文字（招牌、門牌、指示牌）。
     *
     * ## 設計約束（來自 docs/superpowers/specs/2026-10-09-positioning-and-ocr-evaluation.md）
     *
     * - **按需啟動，不常駐**：辨識器每次呼叫才建立、用完就關。本機
     *   （SD685，無 NNAPI/GPU delegate）跑單一 int8 模型已經是 5.2 fps、
     *   約 187 ms/次，CPU 基本滿載；常駐第二個辨識器會互搶 CPU。
     * - **只讀既有的那幀副本**，不另做一次 `ImageAnalysis.Analyzer` 取幀。
     *   多一個 analyzer 會與偵測搶影格，而 CameraX 的背壓策略是
     *   KEEP_ONLY_LATEST，搶影格等於直接降低偵測幀率。
     *
     * ## 為什麼走 JPEG 繞一圈
     *
     * 純 CPU 也能把 YUV 直接轉 ARGB，但那是一段**容易寫錯又不報錯**的色彩轉換
     * 數學（色度取樣位置、奇偶行、行列步長），錯了只會讓 OCR 準確率默默變差。
     * 這裡改用 repo 裡**既有的、已在真機驗證過**的 YUV→JPEG→Bitmap 路徑
     * （[yuvPlanesToNv21] + [rotateJpegIfNeeded]，與採集同一套）。代價是多一次
     * 編解碼，所以把各段耗時一併回報，讓瓶頸看得見而不是猜。
     *
     * ## 回包
     *
     * `{ok, text, elements: [{text, bounds, cornerPoints, confidence}],
     *   decodeMs, ocrMs, totalMs, width, height}`；失敗時 `{ok: false, error}`。
     *
     * 回包**不含像素**：座標是相對於回報的 width/height，Dart 側要畫框再自己映射。
     */
    private fun readLastCaptureText(): Map<String, Any?> {
        val snap = lastCapture
            ?: return mapOf("ok" to false, "error" to "尚無相機幀")

        val totalStart = System.nanoTime()
        var decodeMs = 0.0
        var bitmap: Bitmap? = null
        var recognizer: com.google.mlkit.vision.text.TextRecognizer? = null

        try {
            // ---- 1. 既有 YUV 副本 -> 正立 Bitmap ----
            val decodeStart = System.nanoTime()
            val nv21 = yuvPlanesToNv21(
                snap.y, snap.u, snap.v, snap.width, snap.height, snap.chromaWidth,
            )
            val yuv = YuvImage(nv21, ImageFormat.NV21, snap.width, snap.height, null)
            val rawJpeg = ByteArrayOutputStream().use { out ->
                if (!yuv.compressToJpeg(Rect(0, 0, snap.width, snap.height), 85, out)) {
                    error("JPEG 壓縮失敗")
                }
                out.toByteArray()
            }
            // rotateJpegIfNeeded 對 0 度會原樣回傳，所以這裡一律再解碼一次，
            // 免得 0 度與 90 度走兩條不同的路徑（那就多一條沒被驗證過的分支）。
            val (jpeg, outW, outH) = rotateJpegIfNeeded(
                rawJpeg, snap.width, snap.height, snap.rotationDegrees,
            )
            val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
                ?: error("JPEG 解碼為 Bitmap 失敗（${jpeg.size} bytes）")
            bitmap = bmp
            decodeMs = (System.nanoTime() - decodeStart) / 1_000_000.0

            val image = InputImage.fromBitmap(bmp, 0)

            // ---- 2. 用 CountDownLatch 把 ML Kit 的非同步 Task 接回同步流程 ----
            // 必須等一下，因為回包要在這個 method channel 呼叫裡送回。
            // 10 秒只是**保險絲**：真機上 OCR 是百毫秒級，若真的撞到 10 秒，
            // 那本身就是必須讓使用者看見的結果（比無限期卡住好）。
            val latch = java.util.concurrent.CountDownLatch(1)
            var text: com.google.mlkit.vision.text.Text? = null
            var failure: Exception? = null

            val client = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
            recognizer = client
            val ocrStart = System.nanoTime()
            client.process(image)
                .addOnSuccessListener { text = it }
                .addOnFailureListener { failure = it as? Exception ?: Exception(it) }
                .addOnCompleteListener { latch.countDown() }

            if (!latch.await(10, java.util.concurrent.TimeUnit.SECONDS)) {
                return mapOf("ok" to false, "error" to "OCR 逾時（>10s）", "decodeMs" to decodeMs)
            }
            val ocrMs = (System.nanoTime() - ocrStart) / 1_000_000.0
            failure?.let { throw it }

            val recognized = text
                ?: return mapOf("ok" to false, "error" to "OCR 無回包", "decodeMs" to decodeMs)

            // ---- 3. 只搬葉節點欄位，不搬 ML Kit 的活物件 ----
            val elements = recognized.textBlocks.flatMap { block ->
                block.lines.flatMap { line -> line.elements }
            }.map { el ->
                mapOf(
                    "text" to el.text,
                    // 像素座標，原點在**正立之後**的左上角，與回報的 width/height 同一座標系。
                    "bounds" to mapOf(
                        "left" to el.boundingBox?.left,
                        "top" to el.boundingBox?.top,
                        "right" to el.boundingBox?.right,
                        "bottom" to el.boundingBox?.bottom,
                    ),
                    "cornerPoints" to el.cornerPoints?.map { listOf(it.x, it.y) },
                    // ML Kit 的 `confidence` 只在辨識器 options 開啟時才有效，
                    // 所以型別與數值都可能變；一律轉成 Double 過通道，Dart 側防禦式解析。
                    "confidence" to el.confidence.toDouble(),
                )
            }

            val totalMs = (System.nanoTime() - totalStart) / 1_000_000.0
            Log.i(
                TAG,
                "OCR：${elements.size} 個元素 / ${recognized.text.length} 字，" +
                    "解碼 ${"%.0f".format(decodeMs)} ms，辨識 ${"%.0f".format(ocrMs)} ms，" +
                    "合計 ${"%.0f".format(totalMs)} ms（$outW x $outH）",
            )

            return mapOf(
                "ok" to true,
                "text" to recognized.text,
                "elements" to elements,
                "decodeMs" to decodeMs,
                "ocrMs" to ocrMs,
                "totalMs" to totalMs,
                "width" to outW,
                "height" to outH,
            )
        } catch (e: Exception) {
            Log.e(TAG, "readText 失敗", e)
            return mapOf(
                "ok" to false,
                "error" to "${e.javaClass.simpleName}: ${e.message}",
                "decodeMs" to decodeMs,
            )
        } finally {
            // 兩個都是原生資源，且是**每次呼叫新建**的，所以一定要關——
            // 這個 spike 會被反覆呼叫，漏關就是穩定的記憶體成長。
            runCatching { recognizer?.close() }
                .onFailure { Log.w(TAG, "關閉 OCR 辨識器失敗", it) }
            runCatching { bitmap?.recycle() }
                .onFailure { Log.w(TAG, "回收 OCR bitmap 失敗", it) }
        }
    }

    /**
     * 建一個辨識器。
     *
     * ## 為什麼目前只有中文辨識器可選
     *
     * 真機觀察到**英文被逐字母唸出**。可能的來源有兩個，修法完全不同：
     *  1. **圖太小**（現在是 640×480）→ 低解析度下拉丁字被切成單字元的 element，
     *     提高取像解析度就能解；
     *  2. **辨識器語系**→ 中文模型對拉丁字的切詞不如拉丁模型，要換
     *     `com.google.mlkit:text-recognition`（另一個 artifact，會再增大 APK）。
     *
     * 先用本檔的 `ocrFile` 入口在**同一張圖**上比不同解析度，確定是哪一種。
     * 若 (1) 就能解，就不必為了 (2) 多揹一個模型進 APK——這台手機的 APK
     * 已經 219 MB，而每一次加模型都是實打實的體積。
     */
    private fun makeRecognizer(
        script: String,
    ): com.google.mlkit.vision.text.TextRecognizer {
        if (script == "la") {
            // 尚未引入拉丁模型。與其靜默 fallback（會讓對照實驗給出錯誤結論），
            // 不如明確失敗——這正是本專案反覆強調的「不要靜默」。
            throw IllegalArgumentException(
                "script=la 未實作：需要先加 com.google.mlkit:text-recognition 依賴",
            )
        }
        return TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    /**
     * 診斷入口：對**指定圖片檔**跑 OCR，可指定長邊上限與辨識器語系。
     *
     * 入參 `{path, maxDim?, script?}`；回包與 `readText` 同格式，另加
     * `sourceWidth`/`sourceHeight`/`width`/`height`，方便比較不同解析度的效果。
     *
     * 這不是產品路徑——產品用的是 [readLastCaptureText]（吃相機幀）。
     * 留著它是為了「同一張圖、不同條件」的對照實驗，見
     * `ocrFileCall` 的說明。
     */
    private fun ocrFileCall(call: MethodCall): Map<String, Any?> {
        val path = call.argument<String>("path")
            ?: return mapOf("ok" to false, "error" to "缺少 path")
        val maxDim = call.argument<Int>("maxDim") ?: 0
        val script = call.argument<String>("script") ?: "zh"

        val file = File(path)
        if (!file.exists()) return mapOf("ok" to false, "error" to "檔案不存在：$path")

        var bitmap: Bitmap? = null
        var scaled: Bitmap? = null
        var recognizer: com.google.mlkit.vision.text.TextRecognizer? = null
        val totalStart = System.nanoTime()
        try {
            val src = BitmapFactory.decodeFile(path)
                ?: return mapOf("ok" to false, "error" to "解碼失敗：$path")
            bitmap = src

            val bmp = if (maxDim > 0 && max(src.width, src.height) > maxDim) {
                val scale = maxDim.toFloat() / max(src.width, src.height)
                val w = max(1, (src.width * scale).toInt())
                val h = max(1, (src.height * scale).toInt())
                Bitmap.createScaledBitmap(src, w, h, true).also { scaled = it }
            } else {
                src
            }

            val image = InputImage.fromBitmap(bmp, 0)
            val latch = java.util.concurrent.CountDownLatch(1)
            var text: com.google.mlkit.vision.text.Text? = null
            var failure: Exception? = null

            val client = makeRecognizer(script)
            recognizer = client
            val t0 = System.nanoTime()
            client.process(image)
                .addOnSuccessListener { text = it }
                .addOnFailureListener { failure = it as? Exception ?: Exception(it) }
                .addOnCompleteListener { latch.countDown() }
            if (!latch.await(15, java.util.concurrent.TimeUnit.SECONDS)) {
                return mapOf("ok" to false, "error" to "OCR 逾時")
            }
            failure?.let { throw it }
            val ocrMs = (System.nanoTime() - t0) / 1_000_000.0
            val rec = text ?: return mapOf("ok" to false, "error" to "OCR 無回包")

            val elements = rec.textBlocks.flatMap { b -> b.lines.flatMap { l -> l.elements } }
            return mapOf(
                "ok" to true,
                "text" to rec.text,
                "elementTexts" to elements.map { it.text },
                "elementCount" to elements.size,
                "sourceWidth" to bitmap!!.width,
                "sourceHeight" to bitmap!!.height,
                "width" to bmp.width,
                "height" to bmp.height,
                "ocrMs" to ocrMs,
                "totalMs" to (System.nanoTime() - totalStart) / 1_000_000.0,
                "script" to script,
            )
        } catch (e: Exception) {
            return mapOf("ok" to false, "error" to "${e.javaClass.simpleName}: ${e.message}")
        } finally {
            runCatching { recognizer?.close() }
            runCatching { scaled?.recycle() }
            runCatching { bitmap?.recycle() }
        }
    }

    /** 紧凑 Y/U/V 平面 → NV21（Y + 交错 V/U）。 */
    private fun yuvPlanesToNv21(
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        width: Int,
        height: Int,
        chromaWidth: Int,
    ): ByteArray {
        val frameSize = width * height
        val nv21 = ByteArray(frameSize + frameSize / 2)
        System.arraycopy(y, 0, nv21, 0, min(y.size, frameSize))
        val chromaHeight = height / 2
        var dst = frameSize
        for (row in 0 until chromaHeight) {
            val rowBase = row * chromaWidth
            for (col in 0 until chromaWidth) {
                val i = rowBase + col
                nv21[dst++] = if (i < v.size) v[i] else 0
                nv21[dst++] = if (i < u.size) u[i] else 0
            }
        }
        return nv21
    }

    private fun rotateJpegIfNeeded(
        jpeg: ByteArray,
        width: Int,
        height: Int,
        rotationDegrees: Int,
    ): Triple<ByteArray, Int, Int> {
        val deg = ((rotationDegrees % 360) + 360) % 360
        if (deg == 0) return Triple(jpeg, width, height)
        val src = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            ?: return Triple(jpeg, width, height)
        val matrix = Matrix().apply { postRotate(deg.toFloat()) }
        val rotated = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
        if (rotated !== src) src.recycle()
        val out = ByteArrayOutputStream()
        rotated.compress(Bitmap.CompressFormat.JPEG, 85, out)
        val outW = rotated.width
        val outH = rotated.height
        rotated.recycle()
        return Triple(out.toByteArray(), outW, outH)
    }

    /** 单帧分析：YUV -> 检测 -> EventChannel。
     *
     * 取全部三个平面（Y / U / V），因为模型需要 RGB 输入；
     * 只取 Y 当灰度的做法实测会让置信度掉到阈值以下（详见 detectYuv 的说明）。
     *
     * 每个 return 分支都会累加 [analyzedFrames] 与 [lastAnalyzeSkip]，并把计数
     * 随结果一起回传。**这是刻意的**：曾出现「预览正常但推理 0 次」的情况，
     * 而当时拿不到任何计数信息，只能靠猜。现在 HUD 会直接显示「分析 N 帧」。
     */
    private fun analyze(image: ImageProxy) {
        // 必须无论成败都 close，否则 CameraX 停止投递新帧，表现为画面卡死。
        try {
            analyzedFrames++
            val det = detector
            if (det == null) { lastAnalyzeSkip = "模型未就绪"; return }
            if (currentPreview == null) { lastAnalyzeSkip = "预览未就绪"; return }

            val w = image.width
            val h = image.height
            val rotation = image.imageInfo.rotationDegrees
            val fmt = "planes=${image.planes.size} ${w}x$h rot=$rotation"
            if (image.planes.size < 3) {
                lastAnalyzeSkip = "帧平面数 ${image.planes.size} < 3（$fmt）"
                return
            }
            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]
            val yBytes = copyPlane(
                yPlane.buffer, yPlane.rowStride, w, h, yPlane.pixelStride,
                "Y(row=$w h=$h rs=${yPlane.rowStride} ps=${yPlane.pixelStride} lim=${yPlane.buffer.limit()})",
            )
            // UV 平面是 2x2 下采样，按半宽半高取
            val cw = (w + 1) / 2
            val ch = (h + 1) / 2
            val uBytes = copyPlane(
                uPlane.buffer, uPlane.rowStride, cw, ch, uPlane.pixelStride,
                "U(rs=${uPlane.rowStride} ps=${uPlane.pixelStride} lim=${uPlane.buffer.limit()})",
            )
            val vBytes = copyPlane(
                vPlane.buffer, vPlane.rowStride, cw, ch, vPlane.pixelStride,
                "V(rs=${vPlane.rowStride} ps=${vPlane.pixelStride} lim=${vPlane.buffer.limit()})",
            )

            // 在 ImageProxy.close 之前留下一帧紧凑拷贝，供定时采集落盘。
            // 即使本帧因 isBusy 跳过推理，采集仍能拿到最新画面。
            lastCapture = LastCaptureFrame(
                y = yBytes,
                u = uBytes,
                v = vBytes,
                width = w,
                height = h,
                chromaWidth = cw,
                rotationDegrees = rotation,
            )

            if (det.isBusy) { lastAnalyzeSkip = "上一帧仍在推理"; return }

            val t0 = System.nanoTime()
            val detections = det.detectYuv(
                yBytes, uBytes, vBytes,
                w, h,
                cw,
                rotation, threshold,
            )
            // 只统计纯推理耗时，不含取帧与转换——否则看不出瓶颈在哪。
            val ms = (System.nanoTime() - t0) / 1_000_000.0
            lastFrameWidth = w
            lastFrameHeight = h
            // 同时报**原始平面步长**与**紧凑副本宽度**：UV 取色下标必须按后者算，
            // 两者不一致正是「色度取错、画面变灰」那类缺陷的来源。
            lastFrameFormat = "YUV420 $fmt uvPlane=${uPlane.rowStride}/${uPlane.pixelStride} uvCopy=$cw"
            lastMaxScore = detections.maxOfOrNull { it.score } ?: 0f
            lastMinScore = detections.minOfOrNull { it.score } ?: 0f
            lastDetectionCount = detections.size
            // 成功一帧才清除跳过原因。**不要每帧开头清空**——那样错误信息会
            // 被下一帧覆盖，用户永远看不到（真机上就是这样丢掉线索的）。
            lastAnalyzeSkip = ""
            lastAnalyzeError = ""

            val sink = eventSink ?: run { lastAnalyzeSkip = "EventSink 未连接"; return }
            val payload = mapOf(
                "detections" to detections.map { it.toMap() },
                "inferenceMs" to ms,
                "frameWidth" to w,
                "frameHeight" to h,
                "analyzedFrames" to analyzedFrames,
                "analyzeErrors" to analyzeErrors,
                "skippedReason" to lastAnalyzeSkip,
                "frameMaxScore" to lastMaxScore.toDouble(),
                "frameFormat" to lastFrameFormat,
            )
            ContextCompat.getMainExecutor(context).execute { sink.success(payload) }
        } catch (e: Exception) {
            analyzeErrors++
            // 用 message 而不是 toString，避免刷屏；同时保留类型。
            // ★ 附上**异常发生的第一帧堆栈**：真机上多次出现「只知道异常类型、
            // 不知道哪一行」的情况（例如 IndexOutOfBoundsException: limit=0），
            // 而只靠类型无法定位。取栈顶若干帧足够指出行号。
            val frames = e.stackTrace
                .take(5)
                .joinToString(" <- ") { "${it.className.substringAfterLast('.')}.kt:${it.lineNumber}" }
            lastAnalyzeError = "${e.javaClass.simpleName}: ${e.message ?: "(无消息)"} @ $frames"
            lastAnalyzeSkip = lastAnalyzeError
            Log.w(TAG, "分析帧失败 #$analyzeErrors：$lastAnalyzeError", e)
        } finally {
            image.close()
        }
    }

    /**
     * 从 `ImageBuffer` 拷出指定尺寸的平面。
     *
     * `rowStride` 可能大于逻辑宽度（硬件按 16/32 字节对齐），也可能带
     * `pixelStride`。按 `rowStride` 逐行定位是**必须**的：直接顺序读会在
     * 非对齐设备上产生斜纹伪影，而且不报错。
     *
     * ## 防御性要点
     *
     * 真机上出现过「每帧都抛异常」的情况，300+ 次连续失败，而当时只报了个
     * 计数、看不出原因。所以这里对每个可能不合法的输入都显式检查并**返回
     * 具体原因**，而不是让异常冒泡：
     *  - `rowStride` 为 0 或负数（部分设备的 UV 平面会这样）
     *  - `buffer.limit()` 小于 `rowStride`（读第一行就越界）
     *  - 请求尺寸为 0
     */
    private fun copyPlane(
        buffer: java.nio.ByteBuffer,
        rowStride: Int,
        width: Int,
        height: Int,
        pixelStride: Int,
        what: String,
    ): ByteArray {
        require(width > 0 && height > 0) { "$what 尺寸非法 ${width}x$height" }
        require(rowStride > 0) { "$what rowStride=$rowStride 非法" }
        val stride0 = pixelStride.coerceAtLeast(1)

        val limit = buffer.limit()
        val out = ByteArray(width * height)
        buffer.rewind()

        // 紧凑布局：每行数据连续且无填充
        if (rowStride == width * stride0) {
            if (stride0 == 1) {
                if (limit < out.size) {
                    throw IllegalStateException("$what 数据不足：limit=$limit 需要 ${out.size}")
                }
                buffer.get(out, 0, out.size)
                return out
            }
            var o = 0
            var i = 0
            while (o < out.size) {
                if (i >= limit) throw IllegalStateException("$what 数据不足（pixelStride 读）i=$i limit=$limit")
                out[o++] = buffer.get(i)
                i += stride0
            }
            return out
        }

        // 带行填充：逐行定位。行缓冲区按 rowStride 与逻辑行宽取大者，
        // 并对每行实际可读长度做检查——不检查就会 BufferUnderflow。
        val rowLen = maxOf(rowStride, width * stride0)
        val row = ByteArray(rowLen)
        var o = 0
        for (y in 0 until height) {
            val pos = y * rowStride
            if (pos >= limit) {
                throw IllegalStateException(
                    "$what 第 $y 行越界：pos=$pos limit=$limit rowStride=$rowStride",
                )
            }
            buffer.position(pos)
            val n = min(rowLen, limit - pos)
            if (n <= 0) throw IllegalStateException("$what 第 $y 行无可读数据 n=$n")
            buffer.get(row, 0, n)
            var x = 0
            while (x < width) {
                val src = x * stride0
                if (src >= n) {
                    throw IllegalStateException(
                        "$what 第 $y 行第 $x 列越界：src=$src n=$n " +
                            "(rowStride=$rowStride pixelStride=$stride0 width=$width)",
                    )
                }
                out[o++] = row[src]
                x++
            }
        }
        return out
    }

    // 注：早期这里有一个只取 Y 平面的 readYPlane()。已删除，不再保留死代码。
    // 它对应的灰度输入路径实测会让置信度掉到阈值以下（0.04~0.55 vs RGB 的 0.62~0.82），
    // 表现为「模型明明没问题却检测不到」。现在统一用 copyPlane 取齐 Y/U/V 再做
    // YUV->RGB。要了解详情见 YoloDetector.detectYuv 的注释。
}

/** 预览平台视图。 */
class VisionPreview(private val view: PreviewView) : PlatformView {
    override fun getView(): android.view.View = view
    override fun dispose() {}
}

class VisionPreviewFactory(
    private val context: Context,
    private val plugin: VisionPlugin,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(viewContext: Context?, id: Int, args: Any?): PlatformView {
        val v = PreviewView(context)
        v.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        v.scaleType = PreviewView.ScaleType.FIT_CENTER
        plugin.onPreviewCreated(v)
        return VisionPreview(v)
    }
}

/** 一个检测框，归一化 YOLO 坐标。键名与 platform_contract.dart 一致。 */
data class Detection(
    val id: Int,
    val score: Float,
    val cx: Float,
    val cy: Float,
    val w: Float,
    val h: Float,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "score" to score.toDouble(),
        "cx" to cx.toDouble(),
        "cy" to cy.toDouble(),
        "w" to w.toDouble(),
        "h" to h.toDouble(),
    )
}

/**
 * YOLO 检测器：旋转 + letterbox + LiteRT 推理 + 解码 + NMS。
 *
 * 输出张量按 Ultralytics YOLO11 检测头为 `[1, 4+nc, anchors]`。
 * 类别数**从张量形状反推**，不信任外部类别表——模型与类别表不一致时
 * 靠形状就能发现，比静默错位好。
 */
class YoloDetector private constructor(
    private val interpreter: Interpreter,
    expectedInput: Int,
) {
    companion object {
        /**
         * letterbox 填充值。**必须与训练时一致**。
         *
         * Ultralytics 的预处理用 114 灰填充；若这里用 0（黑边）或别的值，
         * 填充区域与训练分布不符，会拉低置信度且不报错。
         *
         * 定义在本类的 companion 里而不是 VisionPlugin 的：只有本类的
         * detectYuv 用它，放错类会编译不过（顶层类之间不能互访 companion 成员）。
         */
        const val PAD = 114

        /**
         * 从**文件路径**构建，用内存映射。
         *
         * LiteRT 的 `Interpreter` 要求模型缓冲是 `MappedByteBuffer` 或
         * 原生字节序的直接缓冲；传 `ByteBuffer.wrap(byte[])`（堆缓冲）会抛
         * IllegalArgumentException: Model ByteBuffer should be either a
         * MappedByteBuffer of the model file, or a direct ByteBuffer...
         * 内存映射同时省掉一次整模型的内存拷贝。
         */
        fun fromFile(file: java.io.File, expectedInput: Int): YoloDetector {
            val mapped = java.io.RandomAccessFile(file, "r").use { raf ->
                raf.channel.map(
                    java.nio.channels.FileChannel.MapMode.READ_ONLY, 0, raf.length(),
                )
            }
            return YoloDetector(
                Interpreter(mapped, Interpreter.Options().apply { setNumThreads(4) }),
                expectedInput,
            )
        }
    }

    val inputSize: Int
    val numClasses: Int
    private val numAnchors: Int

    /** 输出是否为 `[1, anchors, 4+nc]`。不同导出设置会不同，必须按形状判断。 */
    private val transposed: Boolean

    private val inputBuffer: ByteBuffer
    private val outputBuffer: ByteBuffer

    /**
     * 输入缓冲的 **FloatBuffer 视图**。
     *
     * 用视图而不是 `ByteBuffer.putFloat()` + 手动 `position()`：
     * 后者要自己算字节偏移（`(row * width + col) * 3 * 4`），错一处就会
     * 越写越偏，而且**不报错**。视图的 put 会自动推进指针，只有「写满为止」
     * 一种失败模式，容易发现。
     */
    private val inputFloats: java.nio.FloatBuffer

    /** 输入缓冲字节数与单元素字节数，供启动时校验与诊断。 */
    var inputBufferSize: Int = 0
        private set
    var inputBufferElementBytes: Int = 0
        private set
    var outputBufferSize: Int = 0
        private set

    @Volatile private var busy = false
    val isBusy: Boolean get() = busy

    /**
     * 类别索引映射表：**下标 = 模型本地索引，值 = 项目类别表里的真实 id**。
     *
     * 用处：模型内部只能说 0..nc-1，而 `kLabels[0]` 是 `footbridge_entrance`。
     * 若原样回传，界面会把垃圾桶标成「天橋入口」——**框对、名字错，且不报错**。
     * 例如当前 3 类模型传 `[6, 11, 7]`（pedestrian / bicycle / bin）。
     *
     * **空表 = 不映射**（模型类别数已等于项目类别表，输出即真实 id）。
     *
     * 早先只有一个类时这里是 `classOffset: Int`（加一个常数）。3 类以上
     * 除非真实 id 恰好连续，否则偏移表达不了，所以改成映射表；单类是长度 1 的特例。
     */
    @Volatile var classIds: List<Int> = emptyList()

    @Volatile var lastInferenceMs: Double = 0.0
        private set

    /**
     * 被判定为无效而丢弃的检测数（分数不在 [0,1]、坐标为非有限值、宽高非正）。
     *
     * 注：计数与样本由 [VisionPlugin] 持有而不是本类——对外报状态的是插件，
     * 放在本类会导致插件读不到（顶层类之间无法互访实例成员，编译期就会报错）。
     */

    /** 对外暴露 numAnchors / channels / transposed，便于核对解码假设。 */
    val anchorCount: Int get() = numAnchors
    val channelCount: Int get() = numClasses + 4
    val isTransposed: Boolean get() = transposed

    /**
     * 被判定为无效而丢弃的检测**累计数**。
     *
     * 存在的原因：真机上曾出现「HUD 显示十几个检测框、屏幕上却一个框都没有」，
     * 以及「分数 1.0 几」——而模型的最后一层是 sigmoid，分数不可能超过 1。
     * 两者都指向「解码读错了通道或步长」，但当时没有任何计数能确认。
     *
     * 定义在本类而不是 [VisionPlugin]：递增发生在 [decode] 里，
     * 跨顶层类访问实例成员编译不过（这一点已经被本地编译门禁抓到过）。
     * 插件侧通过 `detector?.invalidCount` 读取。
     */
    @Volatile var invalidCount: Long = 0
        private set

    /**
     * 无效检测按**原因**分类的计数。
     *
     * 只给总数无法区分「分数越界」（解码越界读）、「坐标非有限」（缓冲被破坏）
     * 与「宽高非正」（通道错位）——三者修法完全不同。
     * 真机上出现过「无效检测一直增加」，当时只有总数，只能干猜。
     */
    val invalidByReason: MutableMap<String, Long> = java.util.concurrent.ConcurrentHashMap()

    /** 本帧第一个无效样本的原始数值。只记第一个：它才代表问题模式。 */
    @Volatile var firstInvalidSample: String = ""
        private set

    /**
     * 输入缓冲的真实统计（min / max / 越界个数 / 前 6 个值）。
     *
     * 加它的原因：真机上输出分数出现**负值**（sigmoid 不可能为负），而同一个
     * 模型在电脑上对任意输入都输出合法值。要继续定位就必须知道**写进张量的
     * 到底是什麼**——只看输出无法区分「输入坏了」与「输出读错了」。
     */
    @Volatile var inputStats: String = ""
        private set

    /** 输出缓冲的真实统计（min / max / 非有限个数 / 前 8 个值）。 */
    @Volatile var outputStats: String = ""
        private set

    /**
     * 解码统计：模型**原始输出**的数值范围与**解码后**的分数范围分开报。
     *
     * 这个区分是关键：真机上出现过 `score=-386`（sigmoid 不可能为负），
     * 而在电脑上用同一套解码假设（transposed=True、stride=5）读同一个模型
     * 完全正常（score 0.0001~0.9158）。
     *
     *   raw 正常 + decoded 异常 -> 索引/步长算错
     *   raw 本身异常            -> 缓冲内容不对（写输入或调模型的问题）
     */
    @Volatile var decodeStats: String = ""
        private set

    /**
     * 输入/输出缓冲的 position / limit / capacity 快照。
     *
     * 真机上出现过 `IndexOutOfBoundsException: index=0 out of bounds (limit=0)`
     * ——「limit=0」只可能来自某个空的缓冲，但当时没有数值能确认是哪一个。
     * 这里把两个缓冲（以及 inputBuffer 的 FloatBuffer 视图）的三个指针全列出来。
     */
    @Volatile var bufferState: String = ""
        private set

    init {
        val inShape = interpreter.getInputTensor(0).shape()
        require(inShape.size == 4) { "输入张量应为 4 维，实际 ${inShape.toList()}" }
        require(inShape[3] == 3) { "输入通道应为 3，实际 ${inShape[3]}" }
        inputSize = if (inShape[1] > 0) inShape[1] else expectedInput

        val outShape = interpreter.getOutputTensor(0).shape()
        require(outShape.size == 3) { "输出张量应为 3 维，实际 ${outShape.toList()}" }
        val d1 = outShape[1]
        val d2 = outShape[2]
        // ★ 「锚点优先」当且仅当 anchors 在第 1 维，即 d1 > d2。
        //
        // 这里曾写成 `d1 < d2`——**正好写反**，而且不会有任何报错。
        // 本项目导出的模型是 `[1, 5, 8400]`（通道优先），d1=5 < d2=8400，
        // 于是旧写法判成「锚点优先」，用 `a * stride + c` 去读一个通道优先的
        // 缓冲：读到的全是别的通道的数值，**框坐标被当成了分数**。
        //
        // 真机症状正是如此：HUD 显示十几个框而屏幕上画不出来（框都塌成 0 大小）、
        // 「分数 1.0 几」、以及 `score=-386`（那是像素级坐标）。
        // 同一个模型在电脑上却完全正常，所以只能靠这一行本身来防——
        // `scripts/check_tflite_decode.py` 会读这一行并与模型的真实形状对照。
        transposed = d1 > d2
        val channels = min(d1, d2)
        numAnchors = max(d1, d2)
        numClasses = channels - 4
        require(numClasses > 0) { "无法从输出形状 ${outShape.toList()} 推出类别数" }

        // ★ 缓冲大小**直接用模型声明的字节数**，不自己算。
        //
        // 这里连续错过两次：
        //   第一次：往 ByteBuffer 写了 put(byte)（1 字节）而不是 putFloat(4 字节），
        //            TFLite 报「张量 4915200 字节 vs 缓冲 1228800 字节」。
        //   第二次：改成 putFloat 之后**忘了同步扩大缓冲**，仍然分配
        //           640*640*3 = 1228800，只有所需的 1/4。
        // 两次都是「自己算尺寸」导致的。用 getInputTensor().numBytes() 就与模型
        // 永远一致，不需要人记住 float32 是 4 字节。
        val expectedInputBytes = interpreter.getInputTensor(0).numBytes()
        val expectedOutputBytes = interpreter.getOutputTensor(0).numBytes()
        inputBuffer = ByteBuffer
            .allocateDirect(expectedInputBytes)
            .order(ByteOrder.nativeOrder())
        outputBuffer = ByteBuffer
            .allocateDirect(expectedOutputBytes)
            .order(ByteOrder.nativeOrder())

        inputBufferSize = inputBuffer.capacity()
        inputBufferElementBytes = expectedInputBytes / (inputSize * inputSize * 3)
        require(inputBufferElementBytes == 4) {
            "输入元素应为 4 字节（float32），实际 $inputBufferElementBytes 字节；" +
                "若为 1 说明模型是量化模型（int8），预处理需要相应改动"
        }
        outputBufferSize = outputBuffer.capacity()
        inputFloats = inputBuffer.asFloatBuffer()
        // 在**初始化时**就记录一次缓冲指针，而不是等到推理时。
        // 真机上异常发生在推理过程中，若此时才写快照，出错那一帧的快照就丢了
        // （HUD 上会是空的或旧值，等于没有线索）。初始化时的数值足以判断
        // 「缓冲是否被正确分配」。
        bufferState = ("inBuf(pos=%d,lim=%d,cap=%d) inFloats(cap=%d) " +
            "outBuf(pos=%d,lim=%d,cap=%d)")
            .format(
                inputBuffer.position(), inputBuffer.limit(), inputBuffer.capacity(),
                inputFloats.capacity(),
                outputBuffer.position(), outputBuffer.limit(), outputBuffer.capacity(),
            )

        Log.i(
            VisionPlugin.TAG,
            "模型就绪 input=$inputSize classes=$numClasses anchors=$numAnchors " +
                "transposed=$transposed",
        )
    }

    fun close() {
        runCatching { interpreter.close() }
    }

    /**
     * 用 YUV 帧推理（**转成 RGB**）。
     *
     * ## 曾经犯过的错误：为了速度喂灰度
     *
     * 早期版本只读 `planes[0]`（Y 亮度）当灰度输入，理由是省掉每帧 5–15 ms 的
     * YUV→RGB，并判断「垃圾桶靠形状就能认，颜色不是关键特征」。
     *
     * **那个判断是错的。** 实测同一模型、同一批图（模拟完整预处理流程）：
     *
     *     输入 RGB  -> 最高分 0.62 ~ 0.82
     *     输入灰度 -> 最高分 0.04 ~ 0.55
     *
     * 阈值 0.30 下灰度输入**一个框都不出**。模型明显依赖颜色线索。
     * 省下的几毫秒换来的是完全不可用。
     *
     * 结论：**必须传模型训练时使用的颜色空间**。这类错误不崩溃、不报错，
     * 只表现为「模型明明没问题却检测不到」，极难定位。
     */
    fun detectYuv(
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        frameWidth: Int,
        frameHeight: Int,
        uvWidth: Int,
        rotationDegrees: Int,
        threshold: Float,
    ): List<Detection> {
        if (busy) return emptyList()
        busy = true
        try {
            val rot = ((rotationDegrees % 360) + 360) % 360
            val swap = rot == 90 || rot == 270
            val srcW = if (swap) frameHeight else frameWidth
            val srcH = if (swap) frameWidth else frameHeight

            val scale = min(inputSize.toFloat() / srcW, inputSize.toFloat() / srcH)
            val newW = (srcW * scale).toInt().coerceAtLeast(1)
            val newH = (srcH * scale).toInt().coerceAtLeast(1)
            val padX = (inputSize - newW) / 2
            val padY = (inputSize - newH) / 2

            inputBuffer.rewind()
            // ★ 先用 letterbox 填充色铺满整个输入，再写入真实像素。
            //
            // 训练时 Ultralytics 用 114/255 ≈ 0.447 的灰边填充；如果这里留 0（黑边），
            // 填充区域与训练分布不一致，会拉低置信度。这一点与「灰度输入」是同一类
            // 问题：预处理必须和训练时逐项对齐，差一项都不报错，只是分数变低。
            // 用 FloatBuffer 视图顺序写入，避免手动算字节偏移。
            // 顺序是「先填满填充色，再逐行覆盖真实像素」——填充色与真实内容
            // 都需要写入，所以分两趟：先整幅填 PAD，再把真实区域覆盖回去。
            val padValue = PAD / 255f
            inputFloats.clear()
            val totalPixels = inputSize * inputSize
            var filled = 0
            while (filled < totalPixels) {
                inputFloats.put(padValue).put(padValue).put(padValue)
                filled++
            }
            // 现在把真实内容覆盖到 [padY, padY+newH) x [padX, padX+newW) 区域。
            // 用绝对下标定位（视图没有 position 语义上的字节偏移问题）。
            for (dy in 0 until newH) {
                val rowBase = ((padY + dy) * inputSize + padX) * 3
                for (dx in 0 until newW) {
                    val idx = rowBase + dx * 3
                    val (r, g, b) = sampleRgb(
                        y, u, v, frameWidth, frameHeight, uvWidth,
                        rot, dx, dy, newW, newH,
                    )
                    inputFloats.put(idx, r)
                    inputFloats.put(idx + 1, g)
                    inputFloats.put(idx + 2, b)
                }
            }
            inputFloats.rewind()
            inputBuffer.rewind()

            // ---- 诊断：抓输入缓冲的真实内容 ----
            // 真机曾出现「输出分数为负、前 1631 个锚点正常之后全是垃圾」，
            // 而同一个模型在电脑上对任意输入都输出合法值（越界 0/8400）。
            // 因此必须在真机上直接看**写进去的到底是什么**，而不是继续推理。
            //
            // ★ 整段包 try-catch：诊断代码本身也崩过（真机报
            //   `IndexOutOfBoundsException: index=0 out of bounds (limit=0)`
            //   而三个缓冲的指针快照都是正常的，说明抛异常的可能是诊断自身）。
            //   让诊断失败时说明自己的位置，而不是让整个 analyze 失败。
            run {
                try {
                    inputBuffer.rewind()
                    inputFloats.rewind()
                    val ifCap = inputFloats.capacity()
                    if (ifCap >= 12) {
                        var mn = Float.MAX_VALUE
                        var mx = -Float.MAX_VALUE
                        var bad = 0
                        var k = 0
                        while (k < ifCap) {
                            val v = inputFloats.get(k)
                            if (!v.isFinite() || v < 0f || v > 1f) bad++
                            if (v < mn) mn = v
                            if (v > mx) mx = v
                            k += 1
                        }
                        inputStats = ("cap=%d 越界=%d [%.3f,%.3f] " +
                            "前6=[%.3f,%.3f,%.3f,%.3f,%.3f,%.3f]").format(
                            ifCap, bad, mn, mx,
                            inputFloats.get(0), inputFloats.get(1), inputFloats.get(2),
                            inputFloats.get(3), inputFloats.get(4), inputFloats.get(5),
                        )
                    } else {
                        inputStats = "cap=$ifCap（过小，未统计）"
                    }
                } catch (e: Exception) {
                    inputStats = "诊断失败 ${e.javaClass.simpleName}: ${e.message}"
                }
            }

            outputBuffer.rewind()
            val t0 = System.nanoTime()
            interpreter.run(inputBuffer, outputBuffer)
            lastInferenceMs = (System.nanoTime() - t0) / 1_000_000.0

            // ---- 诊断：抓输出缓冲的真实内容 ----
            // 与输入诊断配套，用来区分「输入坏了」和「输出读错了」。
            // 同样包 try-catch：真机出现过 `... (limit=0)`，而三个缓冲的指针
            // 快照都正常，说明抛异常的可能就是诊断自身。让诊断失败时说出自己。
            run {
                try {
                    // ★ rewind 之后再取视图。
                    // interpreter.run() 会把 outputBuffer 的 position 推到末尾；
                    // 此时 asFloatBuffer() 产生的视图 limit = (limit-pos)/4 = 0，
                    // 于是 ob.get(0) 直接抛
                    //   IndexOutOfBoundsException: index=0 out of bounds (limit=0)
                    // —— 真机上那条错误就是这么来的：**诊断代码自己崩了**，
                    // 而它掩盖了本来要看的信息。
                    outputBuffer.rewind()
                    val ob = outputBuffer.asFloatBuffer()
                    var mn = Float.MAX_VALUE
                    var mx = -Float.MAX_VALUE
                    var bad = 0
                    var k = 0
                    while (k < ob.capacity()) {
                        val x = ob.get(k)
                        if (!x.isFinite()) { bad++ } else {
                            if (x < mn) mn = x
                            if (x > mx) mx = x
                        }
                        k += 1
                    }
                    outputStats = ("cap=%d 非有限=%d [%.3f,%.3f] " +
                        "前8=[%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f]").format(
                        ob.capacity(), bad, mn, mx,
                        ob.get(0), ob.get(1), ob.get(2), ob.get(3),
                        ob.get(4), ob.get(5), ob.get(6), ob.get(7),
                    )
                } catch (e: Exception) {
                    outputStats = "诊断失败 ${e.javaClass.simpleName}: ${e.message} " +
                        "outBuf(pos=${outputBuffer.position()},lim=${outputBuffer.limit()}," +
                        "cap=${outputBuffer.capacity()})"
                }
            }

            val raw = decode(threshold, srcW, srcH, newW, newH, padX, padY)
            return nms(raw, 0.45f, 100)
        } finally {
            busy = false
        }
    }

    /**
     * 取 (dx, dy) 处的 RGB（已归一化到 [0,1]），**只计算不写缓冲**。
     *
     * 之所以只返回数值、由调用方顺序写入：写缓冲的位置管理一旦出错就会
     * 越写越偏且不报错（真机出现过「前 1631 个锚点正常、之后全是垃圾」）。
     * 把「算」和「写」分开，写入点只有一处且是顺序的。
     *
     * 映射链：letterbox 图 -> 正立帧（撤缩放）-> 原始帧（逆旋转）-> YUV 采样 -> RGB。
     *
     * **逆旋转的方向与公式见下面 `when` 里的推导。**
     */
    private fun sampleRgb(
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        frameWidth: Int,
        frameHeight: Int,
        uvWidth: Int,
        rotationDegrees: Int,
        dx: Int,
        dy: Int,
        newW: Int,
        newH: Int,
    ): Triple<Float, Float, Float> {
        val outW = frameWidthOrRotated(frameWidth, frameHeight, rotationDegrees)
        val outH = frameHeightOrRotated(frameWidth, frameHeight, rotationDegrees)
        val ux = dx * outW / newW
        val uy = dy * outH / newH

        // ★ 逆旋转：由「正立图坐标 (ux, uy)」反查「原始帧坐标 (sx, sy)」。
        //
        // Android 里 `rotationDegrees` 的语义是「把原始帧**顺时针**转这么多度才正立」。
        // 顺时针 90 度的**正向**映射是 `destX = SRC_H - 1 - srcY`、`destY = srcX`
        // （注意第二项是 `srcX`，**不是** `SRC_W - 1 - srcX`；后者会多一次镜像）。
        // 反解即：`srcY = SRC_H - 1 - destX`、`srcX = destY`。
        //
        // 这里曾经错得离谱：90 分支写成 `Pair(outH-1-uy, frameWidth-1-ux)`，
        // 两个分量都不对。用 numpy 逐点核对（原始帧 1280x720、rotation=90）：
        // 该写法 **9216 个采样点全部取错源像素（100%）**，正确写法 0 个错。
        // 270 分支写成 `Pair(uy, ux)`（纯转置 = 镜像，缺一次翻转），同样 100% 错。
        // 0 与 180 原本就对，未改动。
        //
        // 为什么特别难发现：`sy` 会算到 [560,1279]，而原始帧只有 720 行，
        // 被下面的 `coerceIn` 夹到 719 —— 于是正立图里约 78% 的区域
        // **全都取的是原始帧的最后一行**，模型看到的基本上是一条糊掉的横线。
        // 而输入诊断（min/max/越界计数）看不出任何异常，因为读到的仍是合法 Y 值。
        // 正确写法下索引天然落在范围内，`coerceIn` 只是防御，不应触发。
        val (sx, sy) = when (rotationDegrees) {
            90 -> Pair(uy, frameHeight - 1 - ux)
            180 -> Pair(frameWidth - 1 - ux, frameHeight - 1 - uy)
            270 -> Pair(frameWidth - 1 - uy, ux)
            else -> Pair(ux, uy)
        }
        val cx = sx.coerceIn(0, frameWidth - 1)
        val cy = sy.coerceIn(0, frameHeight - 1)

        val yVal = y[cy * frameWidth + cx].toInt() and 0xFF
        // ★ UV 下标必须按**紧凑副本**的布局算，不能用原始平面的 rowStride/pixelStride。
        //
        // `copyPlane` 返回的是紧凑数组 `out[y * width + x]`，UV 的 width 就是
        // `(frameWidth + 1) / 2`、pixelStride 已展开为 1。这里曾经写成
        // `(cy/2) * uvRowStride + (cx/2) * uvPixelStride`，用的是**原始平面**的步长：
        // 真机常见的 NV21 布局是 rowStride≈frameWidth、pixelStride=2，于是下标被放大
        // 约 2 倍 —— 上半幅画面取到**错误的色度**，下半幅直接越界，
        // 被下面的 `in u.indices` 兜成 128（中性色 = 灰度）。
        //
        // 表现和「喂灰度图」一模一样：模型仍能跑、分数普遍偏低、颜色线索全丢
        // （本项目实测灰度输入把最高分从 0.62~0.82 压到 0.04~0.55），
        // 而且不报任何错。按紧凑宽度算则恒有 uvIndex ∈ [0, uvWidth*ch)，
        // 无论设备给出什么步长都正确。
        val uvIndex = (cy / 2) * uvWidth + (cx / 2)
        val uVal = if (uvIndex in u.indices) u[uvIndex].toInt() and 0xFF else 128
        val vVal = if (uvIndex in v.indices) v[uvIndex].toInt() and 0xFF else 128

        // 标准 BT.601 YUV -> RGB，输出归一化到 [0,1]。
        // 模型输入是 float32，每个像素 3 个 float；写成 byte 会让字节数差 4 倍。
        val yf = yVal - 16
        val uf = uVal - 128
        val vf = vVal - 128
        val r = (1.164f * yf + 1.596f * vf).coerceIn(0f, 255f) / 255f
        val g = (1.164f * yf - 0.392f * uf - 0.813f * vf).coerceIn(0f, 255f) / 255f
        val b = (1.164f * yf + 2.017f * uf).coerceIn(0f, 255f) / 255f
        return Triple(r, g, b)
    }

    private fun frameWidthOrRotated(w: Int, h: Int, rot: Int): Int =
        if (rot == 90 || rot == 270) h else w

    private fun frameHeightOrRotated(w: Int, h: Int, rot: Int): Int =
        if (rot == 90 || rot == 270) w else h

    /**
     * 输出张量 -> 归一化检测框。
     *
     * 归一化要**三步**，每一步错了都只是数值变垃圾、不报错：
     * 1. 模型坐标是**归一化**到 `inputSize`（含 letterbox 灰边）的比例值，
     *    先 `* inputSize` 才变成该空间里的像素；
     * 2. 减去 `padX/padY` 去掉灰边 -> 缩放后图像内的像素；
     * 3. 除以 `newW/newH` -> 归一化坐标，这正是 Dart 侧期望的坐标系。
     *
     * 第 3 步刻意不用 `scale` 而用 `newW/newH`：后者是
     * `(srcW * scale).toInt()`，与真正贴进画布的那块像素严格一致。
     *
     * 另外，输出张量的**内存布局**必须按形状判断（见 `transposed`）。
     * 坐标换算与布局这两件事互不相干，但错了都会让框变成垃圾。
     * `scripts/check_tflite_decode.py` 在本机把这两件事都对真实图片验证一遍。
     */
    private fun decode(
        threshold: Float,
        srcW: Int,
        srcH: Int,
        newW: Int,
        newH: Int,
        padX: Int,
        padY: Int,
    ): List<Detection> {
        val out = ArrayList<Detection>(64)
        // 每帧重置「第一个无效样本」，否则会一直显示很久以前的旧值。
        var firstInvalidSampleThisFrame: String? = null

        // ---- 解码统计 ----
        // 把「解码后的分数」与「缓冲原始值」分开统计，用于区分：
        //   raw 正常但 decoded 异常 -> 索引/步长算错
        //   raw 本身就异常           -> 缓冲内容不对（写入或模型调用问题）
        var rawMin = Float.MAX_VALUE
        var rawMax = -Float.MAX_VALUE
        var decodedMin = Float.MAX_VALUE
        var decodedMax = -Float.MAX_VALUE
        var bestAnchor = -1
        var bestAnchorScore = -Float.MAX_VALUE
        // 全帧**所有锚点、所有类别**的最高分（不看阈值）。见下面的用法说明。
        var topAllScore = -Float.MAX_VALUE

        // ★ 必须先 rewind 再取 FloatBuffer 视图。
        // interpreter.run() 会把 outputBuffer 的 position 推到末尾；此时
        // asFloatBuffer() 产生的视图 limit = (limit - position)/4 = 0，
        // 之后任何 get 都抛
        //   IndexOutOfBoundsException: index=0 out of bounds (limit=0)
        // 这正是真机上看到的那条错误——**读输出的第一行就崩了**，
        // 于是既没有框、也没有可用的诊断信息。
        outputBuffer.rewind()
        val fb = outputBuffer.asFloatBuffer()
        val stride = numClasses + 4
        for (a in 0 until numAnchors) {
            var best = -1
            var bestScore = threshold
            // 该锚点上**所有类别**的最高分，与阈值无关。
            var rawMax = -Float.MAX_VALUE
            for (c in 0 until numClasses) {
                val v = if (transposed) fb.get(a * stride + 4 + c)
                else fb.get((4 + c) * numAnchors + a)
                if (v > rawMax) rawMax = v
                if (v > bestScore) {
                    bestScore = v
                    best = c
                }
            }
            // ★ 全局最高分（**不看阈值**）。
            //
            // 没有这项时，「本帧无检出」只有一个 maxScore=0，无法区分两种
            // 完全不同的情况：
            //   - 模型确实什么都没看到（topAll 也很低）-> 换个方向/靠近点看；
            //   - 模型看到了但没过阈值（topAll 接近阈值）-> 阈值定得太高。
            // 这两者的处理方式相反，而界面上原本长得一模一样。
            if (rawMax > topAllScore) topAllScore = rawMax
            if (best < 0) continue

            val cx = if (transposed) fb.get(a * stride) else fb.get(a)
            val cy = if (transposed) fb.get(a * stride + 1) else fb.get(numAnchors + a)
            val bw = if (transposed) fb.get(a * stride + 2) else fb.get(2 * numAnchors + a)
            val bh = if (transposed) fb.get(a * stride + 3) else fb.get(3 * numAnchors + a)

            // 统计模型**原始输出**的数值范围（解码前）。与解码后的范围对照，
            // 能区分「索引算错」和「缓冲内容不对」。
            for (raw in arrayOf(bestScore, cx, cy, bw, bh)) {
                if (raw.isFinite()) {
                    if (raw < rawMin) rawMin = raw
                    if (raw > rawMax) rawMax = raw
                }
            }
            if (bestScore > bestAnchorScore) {
                bestAnchorScore = bestScore
                bestAnchor = a
            }
            if (bestScore.isFinite()) {
                if (bestScore < decodedMin) decodedMin = bestScore
                if (bestScore > decodedMax) decodedMax = bestScore
            }

            // ★ 无效值检测。分数必在 [0,1]（模型最后一层是 sigmoid），
            // 坐标必须是有限值，宽高必须为正。
            //
            // 分类计数是必要的：真机上「无效检测一直增加」时，只报一个总数
            // 无法区分是分数越界（解码越界读）、坐标非有限（缓冲被破坏）
            // 还是宽高非正（通道错位）。三者修法完全不同。
            val reason = when {
                bestScore > 1f || bestScore < 0f -> "score_out_of_range"
                !cx.isFinite() || !cy.isFinite() || !bw.isFinite() || !bh.isFinite() ->
                    "non_finite_coord"
                bw <= 0f || bh <= 0f -> "non_positive_wh"
                else -> null
            }
            if (reason != null) {
                invalidCount++
                invalidByReason[reason] = (invalidByReason[reason] ?: 0L) + 1
                // 只记**每帧第一个**无效样本。原来每次都覆盖，最终留下的是
                // 第 8400 个锚点的值——那是噪声，不代表问题模式。
                if (firstInvalidSampleThisFrame == null) {
                    firstInvalidSampleThisFrame =
                        "[$reason] score=$bestScore cx=$cx cy=$cy w=$bw h=$bh anchor=$a"
                }
                continue
            }

            if (newW <= 0 || newH <= 0) continue
            // ★ 模型输出的 cx/cy/w/h 是**归一化**到 letterbox 输入（640x640）的
            //   比例值，**不是像素**。
            //
            // 已用 `scripts/check_tflite_decode.py` 在真实图片上实测：
            // 四个坐标通道的取值范围都是 [0,1]（实测 mean(cx)≈0.498，正是 320/640），
            // 而第 5 个通道是 sigmoid 分数。Ultralytics 的 TFLite 导出就是
            // 归一化过的（与 ONNX 的像素坐标不同），这一点在两端都看不出来。
            //
            // 换算三步，缺任何一步都只是数值变垃圾、不报错：
            //   1. `* inputSize`  -> 加过灰边的 640x640 空间里的像素
            //   2. `- padX/padY`  -> 去掉灰边，得到缩放后图像内的像素
            //   3. `/ newW/newH`  -> 归一化坐标（Dart 侧期望的坐标系）
            //
            // 第 3 步用 newW/newH 而不是 `scale`：newW 就是
            // `(srcW * scale).toInt()`，与真正贴进画布的那块像素严格一致，
            // 用 scale 会引入整数截断造成的半像素级偏差。
            //
            // 旧实现写的是 `(cx - bw / 2) / scale / srcW`：既漏了 `* inputSize`
            // （于是 0.5 被当成 0.5 像素），也漏了减 pad。实测该写法在 8 张真实
            // 图片上的最佳 IoU **全部为 0.000**，正确写法平均 0.860。
            val side = inputSize.toFloat()
            val nx1 = (((cx - bw / 2) * side - padX) / newW).coerceIn(0f, 1f)
            val ny1 = (((cy - bh / 2) * side - padY) / newH).coerceIn(0f, 1f)
            val nx2 = (((cx + bw / 2) * side - padX) / newW).coerceIn(0f, 1f)
            val ny2 = (((cy + bh / 2) * side - padY) / newH).coerceIn(0f, 1f)
            if (nx2 <= nx1 || ny2 <= ny1) continue

            // 映射回项目类别表的真实 id。
            //
            // 越界就**丢弃这个框**而不是原样回传：原样回传等于把一个未知的 id
            // 送给 Dart，那边 `labelOf` 会返回 null，框会被画成"未知类别"。
            // 长度在校验阶段已保证等于类别数，所以这里越界说明有别的问题，
            // 丢框（有计数可查）比画出错名的框安全。
            val appId = if (classIds.isEmpty()) best else classIds.getOrNull(best)
            if (appId == null) continue

            out.add(
                Detection(
                    id = appId,
                    score = bestScore,
                    cx = (nx1 + nx2) / 2,
                    cy = (ny1 + ny2) / 2,
                    w = nx2 - nx1,
                    h = ny2 - ny1,
                ),
            )
        }
        firstInvalidSample = firstInvalidSampleThisFrame ?: firstInvalidSample
        // 没有任何锚点过阈值时，bestAnchor 仍是 -1、bestAnchorScore 仍是
        // -Float.MAX_VALUE。直接按 %f 打出来是一串 40 位的垃圾数字
        // （`best=-340282346638528860000000000000000000000.000@anchor-1`），
        // 既读不懂、又会把 HUD 那一栏撑爆——「本帧没有检出」是**正常状态**，
        // 不该长得像异常。所以显式处理它。
        val bestText = if (bestAnchor >= 0) {
            "%.3f@anchor%d".format(bestAnchorScore, bestAnchor)
        } else {
            "none（无锚点过阈值）"
        }
        // 解码统计。raw 与 decoded 分开报：
        //   raw 正常 + decoded 异常 -> 索引/步长问题
        //   raw 本身异常            -> 缓冲内容问题（写输入或调模型）
        //
        // 末尾的 geo 段是坐标换算的**全部输入**。框画偏时第一眼看这里：
        // 源尺寸、缩放后尺寸、灰边三者任一不对，框就整体错位，而且不报错。
        decodeStats = ("raw[%.3f,%.3f] decoded[%.3f,%.3f] best=%s topAll=%.3f " +
            "transposed=%b stride=%d anchors=%d classes=%d " +
            "geo=%dx%d->%dx%d pad=%d,%d")
            .format(
                if (rawMin <= rawMax) rawMin else 0f,
                if (rawMin <= rawMax) rawMax else 0f,
                if (decodedMin <= decodedMax) decodedMin else 0f,
                if (decodedMin <= decodedMax) decodedMax else 0f,
                bestText,
                if (topAllScore.isFinite()) topAllScore else 0f,
                transposed, stride, numAnchors, numClasses,
                srcW, srcH, newW, newH, padX, padY,
            )
        return out
    }

    private fun nms(input: List<Detection>, iouThreshold: Float, maxDet: Int): List<Detection> {
        if (input.size <= 1) return input
        val sorted = input.sortedByDescending { it.score }
        val keep = ArrayList<Detection>(min(sorted.size, maxDet))
        val suppressed = BooleanArray(sorted.size)
        for (i in sorted.indices) {
            if (suppressed[i]) continue
            keep.add(sorted[i])
            if (keep.size >= maxDet) break
            for (j in i + 1 until sorted.size) {
                if (suppressed[j]) continue
                if (sorted[i].id != sorted[j].id) continue
                if (iou(sorted[i], sorted[j]) > iouThreshold) suppressed[j] = true
            }
        }
        return keep
    }

    private fun iou(a: Detection, b: Detection): Float {
        val ax1 = a.cx - a.w / 2
        val ay1 = a.cy - a.h / 2
        val ax2 = a.cx + a.w / 2
        val ay2 = a.cy + a.h / 2
        val bx1 = b.cx - b.w / 2
        val by1 = b.cy - b.h / 2
        val bx2 = b.cx + b.w / 2
        val by2 = b.cy + b.h / 2
        val iw = min(ax2, bx2) - max(ax1, bx1)
        val ih = min(ay2, by2) - max(ay1, by1)
        if (iw <= 0 || ih <= 0) return 0f
        val inter = iw * ih
        val union = a.w * a.h + b.w * b.h - inter
        return if (union <= 0) 0f else inter / union
    }
}
