package hk.pathguide.pathguide

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingLocationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 刻意**不在这里缓存相机权限状态**：权限由 Dart 侧在启动后申请，
        // 插件必须每次动态检查，并在 Dart 授权后收到 startPreview 才启动相机。
        // 缓存一次会导致授权后仍无预览，且不报任何错。
        flutterEngine.plugins.add(VisionPlugin(context = this))
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hk.pathguide/navigation_permissions",
        ).setMethodCallHandler { call, result ->
            if (call.method != "requestLocation") {
                result.notImplemented()
            } else {
                requestLocationPermission(result)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 屏幕常亮：演示途中息屏会让人以为程序崩了。
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        if (pendingLocationPermissionResult != null) {
            result.error("permission_in_progress", "A location request is already active.", null)
            return
        }
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingLocationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            LOCATION_PERMISSION_REQUEST_CODE,
        )
    }

    @Deprecated("Deprecated in Android")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCATION_PERMISSION_REQUEST_CODE) return
        val locationGranted = permissions.indices.any { index ->
            permissions[index] == Manifest.permission.ACCESS_FINE_LOCATION &&
                grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
        }
        pendingLocationPermissionResult?.success(locationGranted)
        pendingLocationPermissionResult = null
    }

    private companion object {
        const val LOCATION_PERMISSION_REQUEST_CODE = 9021
    }
}
