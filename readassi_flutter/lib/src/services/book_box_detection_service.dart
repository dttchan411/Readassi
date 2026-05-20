import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// 촬영 시작 시 찍은 사진 한 장에서 책(펼침면) 영역의 바운딩 박스를 1회 검출한다.
///
/// OpenCV 파이프라인:
///   블러 → Canny 엣지 → 팽창(끊긴 테두리 잇기) →
///   ② 가로로 긴 close(책등 골을 메워 좌·우 페이지를 하나로 연결) →
///   외곽 윤곽 검출 →
///   ① 면적 임계값을 넘는 모든 윤곽의 바운딩 박스를 모아, 같은 행(세로 겹침)이며
///      가로로 인접한 박스끼리 합쳐 펼침면을 복원 →
///   합쳐진 후보 중 가장 큰 박스 선택 →
///   ③ 세로로 긴(가로:세로 < 1) 박스는 한 페이지만 잡힌 것으로 보고 버림.
class BookBoxDetectionService {
  // 처리 속도를 위해 이 너비로 다운스케일한다.
  static const int _targetWidth = 1000;
  // 책 윤곽으로 인정할 최소 면적(다운스케일 이미지 면적 대비 비율).
  static const double _minAreaRatio = 0.05;
  // ① 후보 박스 병합: 가로 간격이 이미지 너비의 이 비율 이하면 '인접'으로 본다.
  static const double _mergeGapRatio = 0.10;
  // ① 후보 박스 병합: 세로 겹침이 작은 쪽 높이의 이 비율 이상이면 '같은 행'으로 본다.
  static const double _mergeVOverlapRatio = 0.5;
  // ③ 펼침면으로 인정할 최소 가로:세로 비율. 이보다 세로로 길면 한 페이지로 의심.
  static const double _minSpreadAspect = 0.95;

  /// 사진 파일 경로에서 책 박스를 정규화 좌표(0~1)로 돌려준다. 못 찾으면 null.
  /// [excludeRegions]에 손 박스 등을 주면, 엣지 단계에서 그 영역을 통째로
  /// 지워 그 안에는 contour가 생기지 않게 한다(손이 박스에 끼이는 걸 막음).
  Rect? detect(String imagePath, {List<Rect>? excludeRegions}) {
    cv.Mat? gray;
    cv.Mat? resized;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? dilateKernel;
    cv.Mat? dilated;
    cv.Mat? bridgeKernel;
    cv.Mat? bridged;
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
      dilateKernel = cv.getStructuringElement(0 /* MORPH_RECT */, (7, 7));
      dilated = cv.dilate(edges, dilateKernel, iterations: 2);

      // ② 책등(가운데 골)의 세로 틈을 가로로 메운다. close(팽창→침식)는 박스를
      // 바깥으로 부풀리지 않으면서 좌·우 페이지 윤곽을 하나로 잇는다.
      final bridgeW = (tw / 15).round().clamp(25, 90);
      bridgeKernel = cv.getStructuringElement(0, (bridgeW, 5));
      bridged = cv.morphologyEx(dilated, 3 /* MORPH_CLOSE */, bridgeKernel);

      // 손 영역(있다면) 엣지를 통째로 0으로 지워 contour가 생기지 않게 한다.
      // 모든 morphology 이후에 지워, 인접 책 엣지가 손 영역으로 늘어나는 것까지 차단.
      if (excludeRegions != null && excludeRegions.isNotEmpty) {
        const int margin = 12; // 손 가장자리(반그림자)까지 여유 있게 지움
        for (final region in excludeRegions) {
          final x1 = ((region.left * tw).round() - margin).clamp(0, tw - 1);
          final y1 = ((region.top * th).round() - margin).clamp(0, th - 1);
          final x2 = ((region.right * tw).round() + margin).clamp(x1 + 1, tw);
          final y2 = ((region.bottom * th).round() + margin).clamp(y1 + 1, th);
          cv.rectangle(
            bridged,
            cv.Rect(x1, y1, x2 - x1, y2 - y1),
            cv.Scalar.all(0),
            thickness: -1,
          );
        }
        debugPrint(
          "손 영역 ${excludeRegions.length}개 엣지 제거 — 다운스케일 ${tw}x$th 기준",
        );
      }

      // RETR_EXTERNAL(0): 가장 바깥 윤곽만. CHAIN_APPROX_SIMPLE(2).
      final found = cv.findContours(bridged, 0, 2);
      contours = found.$1;
      hierarchy = found.$2;

      final minArea = tw * th * _minAreaRatio;

      // ① 면적 임계값을 넘는 모든 윤곽의 바운딩 박스를 후보로 모은다.
      // 각 박스는 [left, top, right, bottom](다운스케일 픽셀).
      final rects = <List<int>>[];
      for (int i = 0; i < contours.length; i++) {
        if (cv.contourArea(contours[i]) < minArea) continue;
        final r = cv.boundingRect(contours[i]);
        rects.add([r.x, r.y, r.x + r.width, r.y + r.height]);
      }
      if (rects.isEmpty) return null;

      // ① 같은 행(세로 겹침)이며 가로로 인접한 박스끼리 합쳐 펼침면을 복원한다.
      // 책등이 끊겨 좌·우 페이지가 따로 잡혀도 여기서 하나로 합쳐진다.
      final maxGap = tw * _mergeGapRatio;
      bool mergedAny = true;
      while (mergedAny) {
        mergedAny = false;
        for (int i = 0; i < rects.length && !mergedAny; i++) {
          for (int j = i + 1; j < rects.length; j++) {
            if (_shouldMerge(rects[i], rects[j], maxGap)) {
              rects[i] = [
                math.min(rects[i][0], rects[j][0]),
                math.min(rects[i][1], rects[j][1]),
                math.max(rects[i][2], rects[j][2]),
                math.max(rects[i][3], rects[j][3]),
              ];
              rects.removeAt(j);
              mergedAny = true;
              break;
            }
          }
        }
      }

      // 합쳐진 후보 중 면적이 가장 큰 박스를 책 박스로 택한다.
      List<int>? best;
      int bestArea = 0;
      for (final r in rects) {
        final area = (r[2] - r[0]) * (r[3] - r[1]);
        if (area > bestArea) {
          bestArea = area;
          best = r;
        }
      }
      if (best == null) return null;

      final bw = best[2] - best[0];
      final bh = best[3] - best[1];
      if (bw <= 0 || bh <= 0) return null;

      // ③ 단일 페이지 거르기 — 펼친 책 펼침면은 가로로 넓다(가로:세로 > 1).
      // 세로로 긴 박스는 책 중간(책등)만 윤곽으로 잡혀 한 페이지만 인식된
      // 경우이므로 버린다. (null이면 호출부가 프레임 전체로 폴백한다.)
      if (bw / bh < _minSpreadAspect) return null;

      return Rect.fromLTRB(best[0] / tw, best[1] / th, best[2] / tw, best[3] / th);
    } catch (_) {
      return null;
    } finally {
      gray?.dispose();
      resized?.dispose();
      blurred?.dispose();
      edges?.dispose();
      dilateKernel?.dispose();
      dilated?.dispose();
      bridgeKernel?.dispose();
      bridged?.dispose();
      contours?.dispose();
      hierarchy?.dispose();
    }
  }

  /// 손 박스(정규화 Rect, 0~1)들의 영역에서 엣지를 통째로 지운 뒤 책 박스를
  /// 검출한다. 손이 만든 엣지/contour가 사라져 책 박스가 손 따라 늘어나지 않는다.
  /// (cv.inpaint 없이도 동일한 효과 — opencv_dart 안드로이드 빌드에 inpaint
  /// 심볼이 빠져 있어 이 방식으로 우회.)
  /// [handRegions]가 비면 그대로 [detect]를 호출한다.
  Rect? detectWithHandMask(String imagePath, List<Rect> handRegions) {
    if (handRegions.isEmpty) return detect(imagePath);
    return detect(imagePath, excludeRegions: handRegions);
  }

  /// 두 바운딩 박스 [a], [b]([l,t,r,b])를 합칠지 판정한다.
  /// 세로로 충분히 겹치고(같은 행) 가로로 인접/겹치면(간격 ≤ [maxGap]) true.
  bool _shouldMerge(List<int> a, List<int> b, double maxGap) {
    // 세로 겹침 — 같은 행(좌·우 페이지)인지.
    final overlapY = math.min(a[3], b[3]) - math.max(a[1], b[1]);
    if (overlapY <= 0) return false;
    final minH = math.min(a[3] - a[1], b[3] - b[1]);
    if (minH <= 0 || overlapY < _mergeVOverlapRatio * minH) return false;
    // 가로 간격 — 겹치면 음수, 떨어져 있으면 양수. 인접하면 합친다.
    final gapX = math.max(a[0], b[0]) - math.min(a[2], b[2]);
    return gapX <= maxGap;
  }
}
