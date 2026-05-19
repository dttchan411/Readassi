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
  final Rect? bookBox;
  final String captureStatusLabel;
  final String? ocrSummary;
  final bool handLatched;
  final HandBox? trackedHandBox;
  final bool handCoversText;
  final double spineX;
  final bool spineManualOverride;
  final ValueChanged<double>? onSpineChanged;
  final VoidCallback? onSpineAutoReset;
  final List<bool> cellCoverage;
  final List<bool> cellCollected;
  final VoidCallback? onShowFullOcr;

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
    this.bookBox,
    this.captureStatusLabel = '대기 중',
    this.ocrSummary,
    this.handLatched = false,
    this.trackedHandBox,
    this.handCoversText = false,
    this.spineX = 0.5,
    this.spineManualOverride = false,
    this.onSpineChanged,
    this.onSpineAutoReset,
    this.cellCoverage = const [],
    this.cellCollected = const [],
    this.onShowFullOcr,
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
                  // 책 테두리 박스 + 8칸 격자 — 항상 표시. 칸 음영은 디버그일 때만.
                  CustomPaint(
                    painter: _BookBoxPainter(
                      bookBox,
                      debugEnabled ? cellCoverage : const [],
                      debugEnabled ? cellCollected : const [],
                    ),
                  ),
                  if (debugEnabled)
                    CustomPaint(
                      painter: _HandBoxPainter(
                        handResult?.boxes ?? const [],
                        trackedHandBox,
                        spineX,
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
            handCoversText ? "손 위치: 본문 가림" : "손 위치: 가장자리/여백 (촬영 허용)",
            handCoversText
                ? const Color(0xFFFF8A80)
                : const Color(0xFF69F0AE),
          ),
        );
      }
    }

    if (cellCoverage.isNotEmpty) {
      int collectedCount = 0;
      // 4행 × 2열 — 행 단위로 좌/우 칸 마크를 표시한다.
      for (int row = 0; row < cellCoverage.length ~/ 2; row++) {
        final rowMarks = StringBuffer();
        for (int col = 0; col < 2; col++) {
          final i = row * 2 + col;
          final collected = i < cellCollected.length && cellCollected[i];
          if (collected) {
            rowMarks.write('●');
            collectedCount++;
          } else if (cellCoverage[i]) {
            rowMarks.write('■');
          } else {
            rowMarks.write('□');
          }
          if (col == 0) rowMarks.write(' | ');
        }
        lines.add(
          _debugLine(
            "${row + 1}행: $rowMarks",
            const Color(0xFFFFD180),
          ),
        );
      }
      lines.add(
        _debugLine(
          "칸 수집: $collectedCount/${cellCoverage.length}  (●수집  ■손가림  □대기)",
          Colors.white54,
        ),
      );
    }

    final ocr = ocrSummary;
    if (ocr != null) {
      lines.add(_debugLine("최근 OCR 결과", const Color(0xFF82B1FF)));
      lines.add(_debugLine(ocr, Colors.white70));
    }

    if (onShowFullOcr != null) {
      lines.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            onTap: onShowFullOcr,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1E88E5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                "OCR 결과 전체보기",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final onSpine = onSpineChanged;
    if (onSpine != null) {
      lines.add(
        _debugLine(
          "책등 위치(명령 3): ${(spineX * 100).round()}%  "
              "(${spineManualOverride ? '수동 보정' : '자동 감지'})",
          const Color(0xFFE040FB),
        ),
      );
      lines.add(
        SizedBox(
          width: 250,
          child: Slider(
            value: spineX.clamp(0.30, 0.70),
            min: 0.30,
            max: 0.70,
            activeColor: const Color(0xFFE040FB),
            inactiveColor: Colors.white24,
            onChanged: onSpine,
          ),
        ),
      );
      if (spineManualOverride && onSpineAutoReset != null) {
        lines.add(
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: GestureDetector(
              onTap: onSpineAutoReset,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF7B1FA2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  "책등 자동 감지로 되돌리기",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
      }
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

/// 검출된 책 테두리 박스(정규화 Rect)와 그 안의 8칸 격자(4행 × 2열)를 그린다.
/// 박스 기준으로 4개의 가로 분할선과 가운데 세로 분할선을 그리고,
/// 디버그 모드에서는 각 칸의 수집/손가림 상태를 음영으로 표시한다.
class _BookBoxPainter extends CustomPainter {
  _BookBoxPainter(this.bookBox, this.cellCoverage, this.cellCollected);

  final Rect? bookBox;
  final List<bool> cellCoverage;
  final List<bool> cellCollected;

  @override
  void paint(Canvas canvas, Size size) {
    final box = bookBox;
    if (box == null) return;
    final rect = Rect.fromLTRB(
      box.left * size.width,
      box.top * size.height,
      box.right * size.width,
      box.bottom * size.height,
    );

    // 8칸 음영 — 디버그 모드에서 cellCoverage/cellCollected가 채워졌을 때만.
    if (cellCoverage.isNotEmpty) {
      final rows = cellCoverage.length ~/ 2;
      for (int i = 0; i < cellCoverage.length; i++) {
        final row = i ~/ 2;
        final col = i % 2;
        final collected = i < cellCollected.length && cellCollected[i];
        final covered = cellCoverage[i];
        final Color? fill = collected
            ? const Color(0x3369F0AE)
            : (covered ? const Color(0x33FF5252) : null);
        if (fill == null) continue;
        final cell = Rect.fromLTRB(
          rect.left + rect.width * col / 2,
          rect.top + rect.height * row / rows,
          rect.left + rect.width * (col + 1) / 2,
          rect.top + rect.height * (row + 1) / rows,
        );
        canvas.drawRect(
          cell,
          Paint()
            ..color = fill
            ..style = PaintingStyle.fill,
        );
      }
    }

    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    final divider = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // 박스 안 4분할 가로선.
    for (int i = 1; i < 4; i++) {
      final y = rect.top + rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), divider);
    }
    // 박스 안 가운데 세로 분할선(좌/우 칸 구분).
    final cx = rect.left + rect.width / 2;
    canvas.drawLine(Offset(cx, rect.top), Offset(cx, rect.bottom), divider);
  }

  @override
  bool shouldRepaint(_BookBoxPainter oldDelegate) =>
      oldDelegate.bookBox != bookBox ||
      oldDelegate.cellCoverage != cellCoverage ||
      oldDelegate.cellCollected != cellCollected;
}

/// 디버그 오버레이를 카메라 프리뷰 위에 그린다.
/// 검출된 손은 초록, 추적 유지 중인 위치는 주황으로 표시하고,
/// 책등(좌우 페이지 분리) 세로선을 나타낸다.
class _HandBoxPainter extends CustomPainter {
  _HandBoxPainter(this.boxes, this.trackedBox, this.spineX);

  final List<HandBox> boxes;
  final HandBox? trackedBox;
  final double spineX;

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
    // 책등(좌우 페이지 분리) 세로선
    final spineXPix = spineX * size.width;
    canvas.drawLine(
      Offset(spineXPix, 0),
      Offset(spineXPix, size.height),
      Paint()
        ..color = const Color(0xFFE040FB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
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
      oldDelegate.spineX != spineX;
}
