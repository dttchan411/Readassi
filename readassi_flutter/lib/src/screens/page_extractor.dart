import 'package:flutter/material.dart';
import '../app_state.dart';

class PageExtractor {
  static int? extractPageNumberEnhanced(
    String fullText,
    BuildContext context,
    String bookId,
  ) {
    final lines = fullText.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return null;

    final regExp = RegExp(r'\b(\d{1,3})\b');
    final appState = AppStateScope.of(context);
    final int? lastPage = appState.findBookById(bookId)?.currentPage;

    // 1. 로직 고정 상태 확인
    if (_lockedLocation == 'bottom') {
      return _findValidNum(lines.length > 5 ? lines.sublist(lines.length - 5) : lines, lastPage);
    } else if (_lockedLocation == 'top') {
      return _findValidNum(lines.length > 5 ? lines.sublist(0, 5) : lines, lastPage, isTop: true);
    }

    // 2~5단계: 상/하단 숫자 및 해당 라인 정보 추출
    final bottomData = _getMaxNumAndLine(lines.length > 5 ? lines.sublist(lines.length - 5) : lines, regExp);
    final topData = _getMaxNumAndLine(lines.length > 5 ? lines.sublist(0, 5) : lines, regExp);

    int? bottomNum = bottomData?['num'];
    int? topNum = topData?['num'];

    int? candidateNum;
    String? candidateLine;
    bool isFromTop = false;

    // 6~8단계: 우선순위 결정 및 챕터 1 예외 처리
    if (bottomNum != null && topNum == null) {
      candidateNum = bottomNum;
      candidateLine = bottomData!['line'];
    } else if (bottomNum == null && topNum != null) {
      candidateNum = topNum + 1;
      candidateLine = topData!['line'];
      isFromTop = true;
    } else if (bottomNum != null && topNum != null) {
      if (bottomNum == 1 && topNum != 1) {
        candidateNum = topNum + 1;
        candidateLine = topData!['line'];
        isFromTop = true;
      } else if (topNum == 1 && bottomNum != 1) {
        candidateNum = bottomNum;
        candidateLine = bottomData!['line'];
      } else {
        int processedTop = topNum + 1;
        if (lastPage == null || (bottomNum - lastPage).abs() <= (processedTop - lastPage).abs()) {
          candidateNum = bottomNum;
          candidateLine = bottomData!['line'];
        } else {
          candidateNum = processedTop;
          candidateLine = topData!['line'];
          isFromTop = true;
        }
      }
    }

    if (candidateNum == null || candidateLine == null) {
      debugPrint("⚠️ 후보 숫자를 찾지 못했습니다.");
      return null;
    }

    debugPrint("🔍 검증 시작 - 후보: $candidateNum, 줄 내용: '$candidateLine'");

    // 9단계: 숫자 비중 검증
    String cleanLine = candidateLine.replaceAll(RegExp(r'\s+'), '');
    int rawNumInText = isFromTop ? candidateNum - 1 : candidateNum;
    if (cleanLine.length > rawNumInText.toString().length + 2) {
      debugPrint("❌ Step 9 실패: 숫자가 줄에서 차지하는 비중이 낮음 (길이: ${cleanLine.length})");
      return null;
    }

    // 10단계: 범위 검증 (±10)
    if (lastPage != null && lastPage != 0) {
      if (candidateNum > lastPage + 10) {
        debugPrint("❌ Step 10 실패: 현재 페이지($lastPage)보다 10 이상 큼");
        return null;
      }
      if (candidateNum < lastPage - 10) {
        debugPrint("❌ Step 10 실패: 현재 페이지($lastPage)보다 10 이상 작음");
        return null;
      }
    }

    debugPrint("✅ 페이지 검출 성공: $candidateNum (출처: ${isFromTop ? '상단' : '하단'})");

    // 카운트 업데이트 및 고정
    if (isFromTop) {
      _topHitCount++;
      _bottomHitCount = 0;
    } else {
      _bottomHitCount++;
      _topHitCount = 0;
    }

    if (_bottomHitCount >= 5) _lockedLocation = 'bottom';
    if (_topHitCount >= 5) _lockedLocation = 'top';

    return candidateNum;
  }

  // 헬퍼 함수들 (static)
  static Map<String, dynamic>? _getMaxNumAndLine(List<String> targetLines, RegExp reg) {
    int? max;
    String? maxLine;
    for (var line in targetLines) {
      final matches = reg.allMatches(line);
      for (var m in matches) {
        int n = int.parse(m.group(1)!);
        if (max == null || n > max) {
          max = n;
          maxLine = line;
        }
      }
    }
    return (max != null) ? {'num': max, 'line': maxLine} : null;
  }

  static int? _getMaxNumFromLines(List<String> targetLines, RegExp reg) {
    int? max;
    for (var line in targetLines) {
      final matches = reg.allMatches(line);
      for (var m in matches) {
        int n = int.parse(m.group(1)!);
        if (max == null || n > max) max = n;
      }
    }
    return max;
  }

  static int? _findValidNum(List<String> targetLines, int? lastPage, {bool isTop = false}) {
    final regExp = RegExp(r'\b(\d{1,3})\b');
    int? bestNum;

    for (var line in targetLines) {
      final matches = regExp.allMatches(line);
      if (matches.isEmpty) continue;

      for (var m in matches) {
        int num = int.parse(m.group(1)!);
        String cleanLine = line.replaceAll(RegExp(r'\s+'), '');
        if (cleanLine.length <= m.group(1)!.length + 2) {
          int processedNum = isTop ? num + 1 : num;

          if (lastPage == null || lastPage == 0 ||
              (processedNum <= lastPage + 10 && processedNum >= lastPage - 10)) {
            if (bestNum == null || processedNum > bestNum) {
              bestNum = processedNum;
            }
          }
        }
      }
    }
    return bestNum;
  }

  // lockedLocation은 static으로 관리 (전역 상태처럼 사용)
  static String? _lockedLocation;
  static int _topHitCount = 0;
  static int _bottomHitCount = 0;
}