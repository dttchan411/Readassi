package com.example.readassi_flutter

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import java.io.ByteArrayOutputStream

/**
 * Wraps MediaPipe HandLandmarker. Receives a YUV_420_888 camera frame (sent
 * from Dart as separate plane byte arrays), converts it to a Bitmap, and runs
 * hand detection. Returns one normalized bounding box per detected hand.
 */
class HandDetector(context: Context) {

    private val landmarker: HandLandmarker

    // VIDEO 모드는 단조 증가하는 타임스탬프를 요구한다.
    private var lastVideoTimestampMs = 0L

    init {
        val baseOptions = BaseOptions.builder()
            .setModelAssetPath("hand_landmarker.task")
            .build()
        // VIDEO 모드: 한 번 잡은 손을 프레임 간 추적해 부분 가림에도 더 오래 버틴다.
        val options = HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(baseOptions)
            .setRunningMode(RunningMode.VIDEO)
            .setNumHands(2)
            .setMinHandDetectionConfidence(0.5f)
            .setMinHandPresenceConfidence(0.3f)
            .setMinTrackingConfidence(0.3f)
            .build()
        landmarker = HandLandmarker.createFromOptions(context, options)
    }

    fun detect(args: Map<*, *>): Map<String, Any> {
        val startedAt = System.currentTimeMillis()

        val width = (args["width"] as Number).toInt()
        val height = (args["height"] as Number).toInt()
        val yBytes = args["yBytes"] as ByteArray
        val uBytes = args["uBytes"] as ByteArray
        val vBytes = args["vBytes"] as ByteArray
        val yRowStride = (args["yRowStride"] as Number).toInt()
        val uvRowStride = (args["uvRowStride"] as Number).toInt()
        val uvPixelStride = (args["uvPixelStride"] as Number).toInt()

        val nv21 = yuv420ToNv21(
            width, height, yBytes, uBytes, vBytes,
            yRowStride, uvRowStride, uvPixelStride,
        )
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val jpegStream = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, width, height), 85, jpegStream)
        val jpegBytes = jpegStream.toByteArray()
        val bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size)
            ?: throw IllegalStateException("YUV 프레임을 비트맵으로 디코드하지 못했습니다.")

        val mpImage = BitmapImageBuilder(bitmap).build()
        var timestampMs = System.currentTimeMillis()
        if (timestampMs <= lastVideoTimestampMs) {
            timestampMs = lastVideoTimestampMs + 1
        }
        lastVideoTimestampMs = timestampMs
        val result = landmarker.detectForVideo(mpImage, timestampMs)

        val boxes = ArrayList<List<Double>>()
        for (hand in result.landmarks()) {
            var minX = 1.0
            var minY = 1.0
            var maxX = 0.0
            var maxY = 0.0
            for (landmark in hand) {
                val x = landmark.x().toDouble()
                val y = landmark.y().toDouble()
                if (x < minX) minX = x
                if (y < minY) minY = y
                if (x > maxX) maxX = x
                if (y > maxY) maxY = y
            }
            boxes.add(
                listOf(
                    minX.coerceIn(0.0, 1.0),
                    minY.coerceIn(0.0, 1.0),
                    maxX.coerceIn(0.0, 1.0),
                    maxY.coerceIn(0.0, 1.0),
                )
            )
        }
        bitmap.recycle()

        return mapOf(
            "detected" to boxes.isNotEmpty(),
            "handCount" to boxes.size,
            "boxes" to boxes,
            "latencyMs" to (System.currentTimeMillis() - startedAt).toInt(),
        )
    }

    fun close() {
        landmarker.close()
    }

    private fun yuv420ToNv21(
        width: Int,
        height: Int,
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        yRowStride: Int,
        uvRowStride: Int,
        uvPixelStride: Int,
    ): ByteArray {
        val nv21 = ByteArray(width * height * 3 / 2)

        var pos = 0
        for (row in 0 until height) {
            val rowStart = row * yRowStride
            for (col in 0 until width) {
                nv21[pos++] = y[rowStart + col]
            }
        }

        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (row in 0 until chromaHeight) {
            val rowStart = row * uvRowStride
            for (col in 0 until chromaWidth) {
                val uvIndex = rowStart + col * uvPixelStride
                // NV21 stores chroma as interleaved V then U.
                nv21[pos++] = if (uvIndex < v.size) v[uvIndex] else 0
                nv21[pos++] = if (uvIndex < u.size) u[uvIndex] else 0
            }
        }
        return nv21
    }
}
