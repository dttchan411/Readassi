import 'dart:ui' show Rect;

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// 촬영 시작 시 찍은 사진 한 장에서 책(문서) 영역의 바운딩 박스를 1회 검출한다.
/// OpenCV 파이프라인: 블러 → Canny 엣지 → 팽창(끊긴 테두리 잇기) →
/// 외곽 윤곽 검출 → 가장 큰 윤곽의 박스.
class BookBoxDetectionService {
  // 처리 속도를 위해 이 너비로 다운스케일한다.
  static const int _targetWidth = 1000;
  // 책 윤곽으로 인정할 최소 면적(다운스케일 이미지 면적 대비 비율).
  static const double _minAreaRatio = 0.05;

  /// 사진 파일 경로에서 책 박스를 정규화 좌표(0~1)로 돌려준다. 못 찾으면 null.
  Rect? detect(String imagePath) {
    cv.Mat? gray;
    cv.Mat? resized;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? kernel;
    cv.Mat? dilated;
    cv.VecVecPoint? contours;
    cv.VecVec4i? hierarchy;
    try {
      gray = cv.imread(imagePath, flags: cv.IMREAD_GRAYSCALE);
      if (gray.isEmpty) return null;
      final srcW = gray.cols;
      final srcH = gray.rows;
      if (srcW < 64 || srcH < 64) return null;

      // 다운스케일.
      final tw = srcW > _targetWidth ? _targetWidth : srcW;
      final th = (srcH * tw / srcW).round();
      resized = cv.resize(gray, (tw, th));

      blurred = cv.gaussianBlur(resized, (5, 5), 0);
      edges = cv.canny(blurred, 50, 150);
      // 끊긴 책 테두리 엣지를 팽창으로 이어, 닫힌 윤곽이 되게 한다.
      kernel = cv.getStructuringElement(0 /* MORPH_RECT */, (7, 7));
      dilated = cv.dilate(edges, kernel, iterations: 2);

      // RETR_EXTERNAL(0): 가장 바깥 윤곽만. CHAIN_APPROX_SIMPLE(2).
      final found = cv.findContours(dilated, 0, 2);
      contours = found.$1;
      hierarchy = found.$2;

      final minArea = tw * th * _minAreaRatio;
      double bestArea = 0;
      int bestIdx = -1;
      for (int i = 0; i < contours.length; i++) {
        final area = cv.contourArea(contours[i]);
        if (area > bestArea && area >= minArea) {
          bestArea = area;
          bestIdx = i;
        }
      }
      if (bestIdx < 0) return null;

      final best = contours[bestIdx];
      int minX = tw, minY = th, maxX = 0, maxY = 0;
      for (int j = 0; j < best.length; j++) {
        final pt = best[j];
        if (pt.x < minX) minX = pt.x;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.y > maxY) maxY = pt.y;
      }
      if (maxX <= minX || maxY <= minY) return null;

      return Rect.fromLTRB(minX / tw, minY / th, maxX / tw, maxY / th);
    } catch (_) {
      return null;
    } finally {
      gray?.dispose();
      resized?.dispose();
      blurred?.dispose();
      edges?.dispose();
      kernel?.dispose();
      dilated?.dispose();
      contours?.dispose();
      hierarchy?.dispose();
    }
  }
}
