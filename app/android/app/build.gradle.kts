import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun findDartDefineValue(name: String): String? {
    val encodedDefines = project.findProperty("dart-defines") as? String ?: return null
    for (encoded in encodedDefines.split(",")) {
        val decoded = try {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            continue
        }
        val separator = decoded.indexOf('=')
        if (separator > 0 && decoded.substring(0, separator) == name) {
            return decoded.substring(separator + 1)
        }
    }
    return null
}

android {
    namespace = "hk.pathguide.pathguide"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "hk.pathguide.pathguide"
        // Google Navigation SDK supports Android API 24 and newer.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["MAPS_API_KEY"] =
            providers.environmentVariable("MAPS_API_KEY").orNull
                ?: findDartDefineValue("MAPS_API_KEY")
                ?: ""
    }

    buildTypes {
        release {
            // TODO: 正式发布前换成自己的签名配置。
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    androidResources {
        // 模型不要压缩打包。
        // AssetManager 默认的 open() 走文件描述符，对压缩存储的资源不适用；
        // 虽然代码里已改用 ACCESS_BUFFER 兜底，但保持未压缩能少一层不确定性
        // （也便于用 openFd 做内存映射）。
        noCompress += "tflite"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")

    // CameraX：预览 + 图像分析共用同一个相机会话。
    // 版本已在 Google Maven 上确认为稳定版（1.6.2）。
    val cameraxVersion = "1.6.2"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")

    // LiteRT（TensorFlow Lite 的后继）：保留 org.tensorflow.lite.Interpreter 类名，
    // 自带 jni/arm64-v8a/liblitert_jni.so，与目标真机（Redmi Note 11T Pro）架构匹配。
    implementation("com.google.ai.edge.litert:litert:2.2.0")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    // OCR（識字）：讀招牌、門牌、指示牌。
    //
    // ★ 這裡寫 `com.google.mlkit:`（綁定版座標），**不是**只寫
    //   `com.google.android.gms:play-services-mlkit-text-recognition-chinese`。
    //
    // ★★ 但「綁定版 vs 未綁定版」的機制跟直覺不同，這裡據實記錄（2026-10-09
    //    實際解開 APK 與 Gradle 快取查證，不是照文件抄的）：
    //
    //   1. `com.google.mlkit:text-recognition-chinese` 這個 AAR **本身幾乎是空的**
    //      —— classes.jar 只有 2 個類別（一個 dynamite ModuleDescriptor 加一個
    //      .properties）。它靠傳遞依賴把真正的東西拉進來。
    //   2. 公開 API 其實住在 **play-services-** 那兩個 AAR 裡：
    //        com.google.mlkit.vision.text.TextRecognition
    //            -> play-services-mlkit-text-recognition-common-19.1.0
    //        ...vision.text.chinese.ChineseTextRecognizerOptions
    //            -> play-services-mlkit-text-recognition-chinese-16.0.1
    //      **所以 `play-services-` 不是「不能用的另一條路」，它是這條路的一部分。**
    //      （先前此處的註解寫「不能用 play-services- 那條，會走按需下載」，
    //        那是**錯的**，已更正。）
    //   3. 「離線可用」的真正來源是 **text-recognition-bundled-common**（17.5 MB AAR）：
    //      它把模型與 native 一起打包。已在 APK 內確認：
    //        lib/arm64-v8a/libmlkit_google_ocr_pipeline.so   (10.5 MB)
    //        assets/mlkit-google-ocr-models/gocr/.../Hani_ctc/...  (Hani = 漢字)
    //      **模型確實在 APK 裡，所以離線成立** —— 這點是驗證過的，不是推論。
    //
    // ★ 體積：本次加入後 debug APK 由 210.5 MB 增至 219.1 MB（+8.6 MB，壓縮後）。
    //   未壓縮約 +28 MB，因為三個 ABI 各帶一份 native library。
    //   若之後要壓，最有效的做法是限制只出 arm64-v8a（真機是 Redmi Note 11T Pro），
    //   但那是全 App 的決定，不在這個 spike 範圍。
    //
    // ★ minSdk：此 API 要求 API 23 以上，本專案是 24，**不需要改**。
    //
    // ★ 版本：以 Gradle 解析為準。`16.0.1` 是查官方文件時的值，
    //   文件會過時，不要把它當成永久正確。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

flutter {
    source = "../.."
}
