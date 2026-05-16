package com.example.readassi_flutter

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val channelName = "readassi/hand_detection"
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var handDetector: HandDetector? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "detect" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("BAD_ARGS", "프레임 인자가 없습니다.", null)
                            return@setMethodCallHandler
                        }
                        executor.execute {
                            try {
                                val detector = handDetector
                                    ?: HandDetector(applicationContext).also { handDetector = it }
                                val response = detector.detect(args)
                                mainHandler.post { result.success(response) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("DETECT_FAILED", e.message, null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        executor.execute { handDetector?.close() }
        executor.shutdown()
        super.onDestroy()
    }
}
