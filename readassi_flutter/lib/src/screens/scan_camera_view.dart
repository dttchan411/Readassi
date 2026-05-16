import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/hand_detection_service.dart';

class ScanCameraView extends StatelessWidget {
  final CameraController controller;
  final double currentZoomLevel;
  final Function(double) onZoomChanged;
  final bool isCapturing;
  final bool isProcessing;
  final VoidCallback onAnalyzePressed;
  final VoidCallback onCapturePressed;
  final VoidCallback onStopPressed;
  final bool debugEnabled;
  final HandDetectionResult? handResult;

  const ScanCameraView({
    super.key,
    required this.controller,
    required this.currentZoomLevel,
    required this.onZoomChanged,
    required this.isCapturing,
    required this.isProcessing,
    required this.onAnalyzePressed,
    required this.onCapturePressed,
    required this.onStopPressed,
    this.debugEnabled = false,
    this.handResult,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: GestureDetector(
              onScaleStart: (details) {},
              onScaleUpdate: (details) {},
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Colors.black,
                    child: CameraPreview(controller),
                  ),
                  if (debugEnabled && handResult != null)
                    CustomPaint(
                      painter: _HandBoxPainter(handResult!.boxes),
                    ),
                ],
              ),
            ),
          ),
        ),

        // 왼쪽 줌 버튼
        Positioned(
          left: 20,
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildZoomButton("3x", 3.0),
              const SizedBox(height: 14),
              _buildZoomButton("2x", 2.0),
              const SizedBox(height: 14),
              _buildZoomButton("1x", 1.0),
            ],
          ),
        ),

        // 오른쪽 액션 버튼
        Positioned(
          right: 20,
          top: 0,
          bottom: 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 78,
                child: OutlinedButton(
                  onPressed: isCapturing ? onStopPressed : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(
                      color: Color(0xFFB5651D),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text(
                    "중지",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: 78,
                child: OutlinedButton(
                  onPressed: isCapturing || isProcessing
                      ? null
                      : onAnalyzePressed,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(
                      color: Color(0xFF855220),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text(
                    "분석",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: 78,
                child: ElevatedButton(
                  onPressed: isCapturing || isProcessing
                      ? null
                      : onCapturePressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB5651D),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: Text(
                    isCapturing ? "촬영 중" : "촬영 시작",
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (debugEnabled)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(child: _buildDebugPanel()),
          ),

        if (isProcessing)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 20),
                  Text(
                    "AI 분석 중...",
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDebugPanel() {
    final result = handResult;
    final lines = <Widget>[
      const Text(
        "디버그 · 손 감지",
        style: TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    ];

    if (!isCapturing) {
      lines.add(_debugLine("촬영 시작 후 손 감지가 동작합니다.", Colors.white70));
    } else if (result == null) {
      lines.add(_debugLine("프레임 분석 대기 중...", Colors.white70));
    } else if (result.error != null) {
      lines.add(_debugLine("오류: ${result.error}", const Color(0xFFFF8A80)));
    } else {
      lines.add(
        _debugLine(
          result.detected ? "손 감지: 예" : "손 감지: 아니오",
          result.detected ? const Color(0xFF69F0AE) : Colors.white,
        ),
      );
      lines.add(
        _debugLine(
          "감지된 손: ${result.handCount}개   지연: ${result.latencyMs} ms",
          Colors.white70,
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }

  Widget _debugLine(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }

  Widget _buildZoomButton(String label, double zoom) {
    final isSelected = (currentZoomLevel.round() == zoom.round());
    return GestureDetector(
      onTap: () => onZoomChanged(zoom),
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFB5651D)
              : Colors.white.withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.black38,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.black87,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}

/// 정규화 좌표로 받은 손 박스를 카메라 프리뷰 위에 그린다.
class _HandBoxPainter extends CustomPainter {
  _HandBoxPainter(this.boxes);

  final List<HandBox> boxes;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = const Color(0xFF69F0AE)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    for (final box in boxes) {
      final rect = Rect.fromLTRB(
        box.left * size.width,
        box.top * size.height,
        box.right * size.width,
        box.bottom * size.height,
      );
      canvas.drawRect(rect, stroke);
    }
  }

  @override
  bool shouldRepaint(_HandBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes;
}
