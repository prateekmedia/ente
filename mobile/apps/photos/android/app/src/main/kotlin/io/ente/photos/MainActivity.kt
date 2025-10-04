package io.ente.photos

import android.content.Intent
import io.ente.photos.service.UploadForegroundService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.ente.photos/fgservice").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, UploadForegroundService::class.java)
                    intent.putExtra("title", call.argument<String>("title") ?: "Ente - Uploading")
                    intent.putExtra("text", call.argument<String>("text") ?: "Preparing uploads")
                    startForegroundService(intent)
                    result.success(true)
                }
                "stop" -> {
                    stopService(Intent(this, UploadForegroundService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
