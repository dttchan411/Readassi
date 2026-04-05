import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class ScanCameraView extends StatelessWidget {
  final CameraController controller;
  final double currentZoomLevel;
  final Function(double) onZoomChanged;
  final bool isAnalyzing;
  final VoidCallback onUpdatePressed;
  final VoidCallback onCapturePressed;

  const ScanCameraView({
    super.key,
    required this.controller,
    required this.currentZoomLevel,
    required this.onZoomChanged,
    required this.isAnalyzing,
    required this.onUpdatePressed,
    required this.onCapturePressed,
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
              child: Container(
                color: Colors.black,
                child: CameraPreview(controller),
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
                  onPressed: isAnalyzing ? null : onUpdatePressed,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Color(0xFFB5651D), width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text("중지", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: 78,
                child: ElevatedButton(
                  onPressed: isAnalyzing ? null : onCapturePressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB5651D),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text("촬영 시작", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),

        if (isAnalyzing)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 20),
                  Text("AI 분석 중...", style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
            ),
          ),
      ],
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
          color: isSelected ? const Color(0xFFB5651D) : Colors.white.withOpacity(0.85),
          shape: BoxShape.circle,
          border: Border.all(color: isSelected ? Colors.white : Colors.black38, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 6, offset: const Offset(0, 3))],
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