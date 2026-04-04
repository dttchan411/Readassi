import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'book_detail_screen.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:flutter/services.dart';

class ScanScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;

  const ScanScreen({super.key, required this.bookId, required this.bookTitle});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";

  Timer? _autoScanTimer;
  bool _isAutoMode = false;
  String _referenceText = ""; // 유사도 비교를 위한 기준 텍스트 (가장 아래 5줄)
  int _topHitCount = 0;       // 상단 번호 감지 연속 횟수
  int _bottomHitCount = 0;    // 하단 번호 감지 연속 횟수
  String? _lockedLocation;    // 'top' 또는 'bottom'으로 고정된 상태

  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false;

  // 줌 관련 변수
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0; // 핀치 제스처 시작 시점의 배율

  // OCR 백그라운드 큐
  final List<Future<void>> _ocrQueue = [];
  int _pendingOcrCount = 0;

@override
  void initState() {
    super.initState();
    
    // ←←← 가로모드 강제 고정
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    _initCamera();
  }

  @override
  void dispose() {
    // ←←← 원래 방향으로 복구 (세로모드 허용)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _autoScanTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      _controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();

      // 기기의 지원 줌 범위 가져오기
      _minZoomLevel = await _controller!.getMinZoomLevel();
      _maxZoomLevel = await _controller!.getMaxZoomLevel();

      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("카메라 에러: $e");
    }
  }

  // 배율 업데이트 함수
  Future<void> _updateZoom(double zoom) async {
    if (_controller == null) return;
    // 지원 범위를 벗어나지 않게 고정
    final double clampedZoom = zoom.clamp(_minZoomLevel, _maxZoomLevel);
    try {
      await _controller!.setZoomLevel(clampedZoom);
      setState(() => _currentZoomLevel = clampedZoom);
    } catch (e) {
      debugPrint("줌 설정 에러: $e");
    }
  }

  Future<String> _getOriginalTextFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    final bookDir = Directory(p.join(dir.path, 'books'));
    await bookDir.create(recursive: true);
    return p.join(bookDir.path, '${widget.bookId}_original.txt');
  }

  Future<void> _enqueueOcr(Uint8List bytes) async {
    final completer = Completer<void>();
    _ocrQueue.add(completer.future);
    setState(() => _pendingOcrCount = _ocrQueue.length);

    try {
      final text = await _getVisionText(bytes);
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final currentBottom5 = lines.length > 5 ? lines.sublist(lines.length - 5).join("\n") : text;

      // 1. 유사도 검사
      if (_referenceText.isNotEmpty) {
        double similarity = _calculateSimilarity(_referenceText, currentBottom5);
        debugPrint("현재 페이지 유사도 검출 결과: $similarity"); // ← 이 줄을 추가하세요.
        
        if (similarity >= 0.5) {
          debugPrint("같은 페이지로 판단되어 스킵합니다.");
          return; 
        }
      }
      // 2. 다른 페이지라면 저장 및 기준 업데이트
      await _appendToOriginalText(text);
      _referenceText = currentBottom5;

      // 3. 페이지 추출 및 업데이트
      final pageNumber = _extractPageNumberEnhanced(text);
      if (pageNumber != null) {
        AppStateScope.of(context).updateBookCurrentPage(widget.bookId, pageNumber);
      }
    } catch (e) {
      debugPrint("OCR 처리 중 오류: $e");
    } finally {
      // 반드시 실행되어 큐를 비워줌
      completer.complete();
      _ocrQueue.removeAt(0);
      if (mounted) {
        setState(() => _pendingOcrCount = _ocrQueue.length);
      }
    }
  }

  Future<String> _getVisionText(Uint8List bytes) async {
    final base64Image = base64Encode(bytes);
    final response = await http.post(
      Uri.parse(
        'https://vision.googleapis.com/v1/images:annotate?key=$_googleVisionApiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'requests': [
          {
            'image': {'content': base64Image},
            'features': [
              {'type': 'DOCUMENT_TEXT_DETECTION'},
            ],
            'imageContext': {
              'languageHints': ['ko'],
            },
          },
        ],
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['responses']?[0]?['fullTextAnnotation']?['text'] ?? "인식 실패";
    }
    return "텍스트 추출 실패";
  }

  Future<void> _appendToOriginalText(String newText) async {
    final file = File(await _getOriginalTextFilePath());
    if (!await file.exists()) await file.create();
    await file.writeAsString('$newText\n\n', mode: FileMode.append);
  }

  Future<void> _takePictureAndProcess() async {
    if (_controller == null || !_controller!.value.isInitialized || _isAnalyzing) return;

    // 자동 촬영 시작 로직 추가
    if (!_isAutoMode) {
      setState(() => _isAutoMode = true);
      _autoScanTimer = Timer.periodic(const Duration(seconds: 8), (timer) async {
        if (!_isAnalyzing) {
          await _takePictureAndProcess();
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("자동 촬영을 시작합니다.")),
      );
    }

    setState(() => _isAnalyzing = true);

    try {
      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();

      _enqueueOcr(bytes);

    } catch (e) {
      debugPrint("촬영 오류: $e");
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _performUpdate() async {
    if (_isAnalyzing) return;
    if (_isAutoMode) {
      _autoScanTimer?.cancel();
      setState(() => _isAutoMode = false);
    }
    setState(() => _isAnalyzing = true);

    try {
      debugPrint("🔄 업데이트 시작 - OCR 큐 처리 중...");
      if (_ocrQueue.isNotEmpty) {
        await Future.wait(_ocrQueue);
      }

      final filePath = await _getOriginalTextFilePath();
      final fullText = await File(filePath).exists() 
          ? await File(filePath).readAsString() 
          : "";

      debugPrint("📊 스캔된 전체 텍스트 길이: ${fullText.length}자");

      if (fullText.trim().isEmpty) {
        throw Exception("스캔된 텍스트가 없습니다. 먼저 페이지를 촬영해주세요.");
      }

      debugPrint("🔍 Gemini 요약 요청 시작...");
      final newSummary = await _getGeminiUpdateSummary(fullText);
      debugPrint("📨 Gemini 응답 전체: [$newSummary]");
      debugPrint("📨 응답 길이: ${newSummary.length}자");

      if (newSummary.contains("실패") || newSummary.contains("오류")) {
        throw Exception("Gemini 요약 실패: $newSummary");
      }

      final appState = AppStateScope.of(context);
      appState.updateBookSummary(widget.bookId, newSummary);

      final finalPage = _extractPageNumberEnhanced(fullText) ?? 0;
      if (finalPage != 0) {
        appState.updateBookCurrentPage(widget.bookId, finalPage);
        debugPrint("✅ 최종 페이지 업데이트: $finalPage P");
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✅ $finalPage 페이지까지 요약 완료"),
            backgroundColor: Colors.green[700],
          ),
        );
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => BookDetailScreen(bookId: widget.bookId)),
        );
      }
    } catch (e, stack) {
      debugPrint("❌ [업데이트 실패] 에러: $e");
      debugPrint("❌ StackTrace: $stack");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("업데이트 실패: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<String> _getGeminiUpdateSummary(String fullText) async {
    final limitedText = fullText.length > 20000
        ? fullText.substring(0, 20000) + "\n...(이후 내용 생략)..."
        : fullText;

    final prompt = """
다음은 책에서 스캔한 전체 내용입니다. 
현재까지 스캔된 페이지 수는 대략 ${fullText.length ~/ 220}페이지 정도입니다.

자연스럽고 읽기 쉽게 핵심 스토리를 약 10줄 내외로 자세히 요약해 주세요.

$limitedText

- "스캔된 내용에 따르면", "요약하자면" 같은 표현은 절대 사용하지 마세요.
- 불릿, 번호, 기호 없이 완전한 문장으로만 작성하세요.
""";

    try {
      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [{"parts": [{"text": prompt}]}],
          "safetySettings": [ /* 기존 safetySettings 그대로 유지 */ ],
          "generationConfig": {
            "temperature": 0.85,
            "maxOutputTokens": 5000,
            "topP": 0.95,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates']?[0]?['content']?['parts']?[0]?['text']?.trim() ?? "요약 실패";
      }
      return "요약 생성 실패 (HTTP ${response.statusCode})";
    } catch (e) {
      debugPrint("Gemini 오류: $e");
      return "통신 오류: $e";
    }
  }

int? _extractPageNumberEnhanced(String fullText) {
  final lines = fullText.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return null;

  final regExp = RegExp(r'\b(\d{1,3})\b');
  final appState = AppStateScope.of(context);
  final int? lastPage = appState.findBookById(widget.bookId)?.currentPage;

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
    // 챕터 번호(1) 예외 로직 적용
    if (bottomNum == 1 && topNum != 1) {
      candidateNum = topNum + 1;
      candidateLine = topData!['line'];
      isFromTop = true;
    } else if (topNum == 1 && bottomNum != 1) {
      candidateNum = bottomNum;
      candidateLine = bottomData!['line'];
    } else {
      // 둘 다 1이 아니거나 둘 다 1인 경우: 이전 페이지와 차이가 적은 수 선택
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

  // 결과값이 없으면 종료
  if (candidateNum == null || candidateLine == null) {
    debugPrint("⚠️ 후보 숫자를 찾지 못했습니다.");
    return null;
  }

  debugPrint("🔍 검증 시작 - 후보: $candidateNum, 줄 내용: '$candidateLine'");

  // 9단계: 숫자 비중(Dominance) 검증
  String cleanLine = candidateLine.replaceAll(RegExp(r'\s+'), '');
  int rawNumInText = isFromTop ? candidateNum - 1 : candidateNum;
  if (cleanLine.length > rawNumInText.toString().length + 2) {
    debugPrint("❌ Step 9 실패: 숫자가 줄에서 차지하는 비중이 낮음 (길이: ${cleanLine.length})");
    return null;
  }

  // 10단계: 범위 검증 (+-10 조건)
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

  // 모든 검증 통과 시 카운트 업데이트 및 고정
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

// 헬퍼 함수 추가: 숫자와 해당 라인을 함께 반환
Map<String, dynamic>? _getMaxNumAndLine(List<String> targetLines, RegExp reg) {
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

// 특정 줄 범위에서 가장 큰 숫자를 찾는 보조 함수
int? _getMaxNumFromLines(List<String> targetLines, RegExp reg) {
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

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final book = AppStateScope.of(context).findBookById(widget.bookId);
    final currentPage = book?.currentPage ?? 0;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: SafeArea(
        top: false, 
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 4), 
              child: Row(
                children: [
                  Transform.translate(
                    offset: const Offset(0, 30), 
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_ios, size: 22, color: Colors.black87),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          widget.bookTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "현재 인식된 페이지: $currentPage P",
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: Colors.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 78,                    // 배지가 차지할 최대 너비 (필요하면 80~85로 조절)
                    child: _pendingOcrCount > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange[700],
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              "OCR ${_pendingOcrCount}",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : const SizedBox(),       // 배지가 없을 때도 공간은 유지
                  ),
                ],
              ),
            ),

            // 카메라 영역
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: GestureDetector(
                        onScaleStart: (details) {
                          _baseZoomLevel = _currentZoomLevel;
                        },
                        onScaleUpdate: (details) {
                          _updateZoom(_baseZoomLevel * details.scale);
                        },
                        child: Container(
                          color: Colors.black,
                          child: CameraPreview(_controller!),
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

                  // 오른쪽 버튼
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
                            onPressed: _isAnalyzing ? null : _performUpdate,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: const BorderSide(color: Color(0xFFB5651D), width: 1.5),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                            ),
                            child: const Text(
                              "중지",
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: 78,
                          child: ElevatedButton(
                            onPressed: _isAnalyzing ? null : _takePictureAndProcess,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFB5651D),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                            ),
                            child: const Text(
                              "촬영 시작",
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_isAnalyzing)
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 줌 버튼
  Widget _buildZoomButton(String label, double zoom) {
    final isSelected = (_currentZoomLevel.round() == zoom.round());
    return GestureDetector(
      onTap: () => _updateZoom(zoom),
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFB5651D) : Colors.white.withOpacity(0.85),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.black38,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
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
// 두 텍스트 사이의 단어 유사도를 계산 (0.0 ~ 1.0)
  double _calculateSimilarity(String s1, String s2) {
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final set1 = s1.split(RegExp(r'\s+')).toSet();
    final set2 = s2.split(RegExp(r'\s+')).toSet();
    final intersection = set1.intersection(set2);
    return (2.0 * intersection.length) / (set1.length + set2.length);
  }

  // 페이지 번호를 검증하고 추출하는 핵심 로직
  int? _findValidNum(List<String> targetLines, int? lastPage, {bool isTop = false}) {
    final regExp = RegExp(r'\b(\d{1,3})\b');
    int? bestNum;

    for (var line in targetLines) {
      final matches = regExp.allMatches(line);
      if (matches.isEmpty) continue;

      for (var m in matches) {
        int num = int.parse(m.group(1)!);
        
        // 숫자가 줄에서 차지하는 비중 확인 (9번 조건)
        String cleanLine = line.replaceAll(RegExp(r'\s+'), '');
        if (cleanLine.length <= m.group(1)!.length + 2) {
          int processedNum = isTop ? num + 1 : num;

          // 현재 페이지 + 10 이내 검증 (10번 조건)
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
}