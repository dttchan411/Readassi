import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// 정규화 좌표(0~1)로 표현된 손 바운딩 박스.
class HandBox {
  const HandBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
}

class HandDetectionResult {
  const HandDetectionResult({
    required this.detected,
    required this.handCount,
    required this.boxes,
    required this.latencyMs,
    this.error,
  });

  final bool detected;
  final int handCount;
  final List<HandBox> boxes;
  final int latencyMs;
  final String? error;

  static const HandDetectionResult empty = HandDetectionResult(
    detected: false,
    handCount: 0,
    boxes: [],
    latencyMs: 0,
  );

  HandDetectionResult.failure(String message)
    : detected = false,
      handCount = 0,
      boxes = const [],
      latencyMs = 0,
      error = message;
}

/// 네이티브 MediaPipe HandLandmarker(Android)를 플랫폼 채널로 호출한다.
class HandDetectionService {
  static const MethodChannel _channel = MethodChannel(
    'readassi/hand_detection',
  );

  Future<HandDetectionResult> detect(CameraImage image) async {
    if (image.planes.length < 3) {
      return HandDetectionResult.failure(
        '지원하지 않는 카메라 이미지 포맷입니다 (planes=${image.planes.length}).',
      );
    }

    try {
      final response = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'detect',
        {
          'width': image.width,
          'height': image.height,
          'yBytes': image.planes[0].bytes,
          'uBytes': image.planes[1].bytes,
          'vBytes': image.planes[2].bytes,
          'yRowStride': image.planes[0].bytesPerRow,
          'uvRowStride': image.planes[1].bytesPerRow,
          'uvPixelStride': image.planes[1].bytesPerPixel ?? 1,
        },
      );

      if (response == null) {
        return HandDetectionResult.failure('네이티브 응답이 비어 있습니다.');
      }

      final rawBoxes = (response['boxes'] as List?) ?? const [];
      final boxes = <HandBox>[];
      for (final raw in rawBoxes) {
        final values = raw as List;
        boxes.add(
          HandBox(
            left: (values[0] as num).toDouble(),
            top: (values[1] as num).toDouble(),
            right: (values[2] as num).toDouble(),
            bottom: (values[3] as num).toDouble(),
          ),
        );
      }

      return HandDetectionResult(
        detected: response['detected'] == true,
        handCount: (response['handCount'] as num?)?.toInt() ?? 0,
        boxes: boxes,
        latencyMs: (response['latencyMs'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      return HandDetectionResult.failure(e.message ?? '손 감지 호출 실패');
    } on MissingPluginException {
      return HandDetectionResult.failure('네이티브 손 감지 채널이 연결되지 않았습니다.');
    }
  }
}
