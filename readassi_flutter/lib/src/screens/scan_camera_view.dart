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
  final String captureStatusLabel;
  final String? ocrSummary;
  final bool handLatched;
  final HandBox? trackedHandBox;
  final double bottomRegionTop;
  final bool handCoversText;
  final ValueChanged<double>? onBottomRegionChanged;

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
    this.captureStatusLabel = '대기 중',
    this.ocrSummary,
    this.handLatched = false,
    this.trackedHandBox,
    this.bottomRegionTop = 0.80,
    this.handCoversText = false,
    this.onBottomRegionChanged,
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
                  if (debugEnabled)
                    CustomPaint(
                      painter: _HandBoxPainter(
                        handResult?.boxes ?? const [],
                        trackedHandBox,
                        bottomRegionTop,
                      ),
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
        "디버그 · 손 가림 OCR",
        style: TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      _debugLine("상태: $captureStatusLabel", const Color(0xFFFFD180)),
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
      if (handLatched && !result.detected) {
        lines.add(
          _debugLine(
            "추적 유지 중 — 손 있음으로 간주",
            const Color(0xFFFFB300),
          ),
        );
      }
      if (handLatched) {
        lines.add(
          _debugLine(
            handCoversText ? "손 위치: 본문 가림" : "손 위치: 하단 여백 (촬영 허용)",
            handCoversText
                ? const Color(0xFFFF8A80)
                : const Color(0xFF69F0AE),
          ),
        );
      }
    }

    final ocr = ocrSummary;
    if (ocr != null) {
      lines.add(_debugLine("최근 OCR 결과", const Color(0xFF82B1FF)));
      lines.add(_debugLine(ocr, Colors.white70));
    }

    final onRegionChanged = onBottomRegionChanged;
    if (onRegionChanged != null) {
      lines.add(
        _debugLine(
          "하단 경계: ${(bottomRegionTop * 100).round()}%  (슬라이더로 조절)",
          const Color(0xFF00E5FF),
        ),
      );
      lines.add(
        SizedBox(
          width: 250,
          child: Slider(
            value: bottomRegionTop.clamp(0.5, 0.95),
            min: 0.5,
            max: 0.95,
            activeColor: const Color(0xFF00E5FF),
            inactiveColor: Colors.white24,
            onChanged: onRegionChanged,
          ),
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
/// 검출된 손은 초록, 추적으로 유지 중인 마지막 위치는 주황으로 표시하고,
/// 하단 여백(촬영 허용 구역)을 청록 경계선과 옅은 음영으로 나타낸다.
class _HandBoxPainter extends CustomPainter {
  _HandBoxPainter(this.boxes, this.trackedBox, this.bottomRegionTop);

  final List<HandBox> boxes;
  final HandBox? trackedBox;
  final double bottomRegionTop;

  void _drawBox(Canvas canvas, Size size, HandBox box, Color color) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final rect = Rect.fromLTRB(
      box.left * size.width,
      box.top * size.height,
      box.right * size.width,
      box.bottom * size.height,
    );
    canvas.drawRect(rect, stroke);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 하단 여백(촬영 허용) 영역 표시
    final regionY = bottomRegionTop * size.height;
    canvas.drawRect(
      Rect.fromLTRB(0, regionY, size.width, size.height),
      Paint()
        ..color = const Color(0x2200B8D4)
        ..style = PaintingStyle.fill,
    );
    canvas.drawLine(
      Offset(0, regionY),
      Offset(size.width, regionY),
      Paint()
        ..color = const Color(0xFF00B8D4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    for (final box in boxes) {
      _drawBox(canvas, size, box, const Color(0xFF69F0AE));
    }
    final tracked = trackedBox;
    if (tracked != null) {
      _drawBox(canvas, size, tracked, const Color(0xFFFFB300));
    }
  }

  @override
  bool shouldRepaint(_HandBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.trackedBox != trackedBox ||
      oldDelegate.bottomRegionTop != bottomRegionTop;
}
