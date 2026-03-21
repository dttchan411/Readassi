import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../app_state.dart';
import '../models/book.dart';
import '../services/claude_service.dart';
import '../widgets/chat_bubble.dart';
import 'book_detail_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({this.existingBookId, super.key});

  final String? existingBookId;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  final TextEditingController _chatController = TextEditingController();
  final ClaudeService _claudeService = ClaudeService();

  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;
  Timer? _tooltipTimer;

  bool _isCameraReady = false;
  bool _isInitializingCamera = false;
  bool _isScanning = false;
  bool _showTooltip = true;
  bool _hasData = false;

  String? _cameraError;
  String _extractedText = '';
  String _summary = '';
  List<String> _keywords = [];
  List<_SimpleCharacter> _characters = [];
  final List<_ChatEntry> _chatMessages = [];
  ScanTab _activeTab = ScanTab.text;

  bool get _supportsLiveCamera {
    if (kIsWeb) {
      return false;
    }

    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tooltipTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _showTooltip = false);
      }
    });
    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tooltipTimer?.cancel();
    _chatController.dispose();
    unawaited(_textRecognizer?.close());
    unawaited(_disposeCamera());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_supportsLiveCamera) {
      return;
    }

    if (state == AppLifecycleState.resumed) {
      if (!_isCameraReady && !_isInitializingCamera) {
        unawaited(_initializeCamera());
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_disposeCamera(resetMessage: false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final existingBook = widget.existingBookId == null
        ? null
        : appState.findBookById(widget.existingBookId!);

    return Scaffold(
      backgroundColor: const Color(0xFF171412),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF2A241F),
                    const Color(0xFF171412),
                    Colors.black.withValues(alpha: 0.96),
                  ],
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 120),
                  Expanded(
                    child: Center(
                      child: _CameraFrame(
                        isScanning: _isScanning,
                        child: _buildCameraArea(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 220),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      _RoundIconButton(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      if (_hasData && !_isScanning)
                        FilledButton.icon(
                          onPressed: () => _saveToLibrary(existingBook),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFD58C40),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.bookmark_add_outlined),
                          label: const Text('기록 저장'),
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                if (!_hasData && _showTooltip && !_isScanning)
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E2925).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF4C443D)),
                    ),
                    child: const Text(
                      '카메라 화면에 책 페이지를 맞춘 뒤\n아래 버튼으로 실시간 스캔을 시작해보세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFF3EDE4), height: 1.5),
                    ),
                  ),
                if (_hasData)
                  _ScanPanel(
                    activeTab: _activeTab,
                    isScanning: _isScanning,
                    extractedText: _extractedText,
                    summary: _summary,
                    keywords: _keywords,
                    characters: _characters,
                    chatMessages: _chatMessages,
                    chatController: _chatController,
                    onTabSelected: (tab) => setState(() => _activeTab = tab),
                    onSendMessage: _sendMessage,
                  ),
                Container(
                  width: double.infinity,
                  color: _hasData
                      ? const Color(0xFFFDFBF7)
                      : Colors.transparent,
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _toggleScan,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 280),
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isScanning
                                ? const Color(0xFFD58C40)
                                : const Color(0xFFF3EFE8),
                            border: Border.all(
                              color: _isScanning
                                  ? const Color(0xFFFFD3A1)
                                  : const Color(0xFF4F443C),
                              width: _isScanning ? 4 : 3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    (_isScanning
                                            ? const Color(0xFFFFB55D)
                                            : Colors.black)
                                        .withValues(alpha: 0.18),
                                blurRadius: 26,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 240),
                              width: _isScanning ? 28 : 56,
                              height: _isScanning ? 28 : 56,
                              decoration: BoxDecoration(
                                color: _isScanning
                                    ? Colors.white
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(
                                  _isScanning ? 8 : 28,
                                ),
                                border: Border.all(
                                  color: _isScanning
                                      ? Colors.white
                                      : const Color(0xFF322B26),
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _isScanning
                            ? '페이지 읽는 중'
                            : (_hasData ? '다시 스캔하기' : '스캔 시작'),
                        style: const TextStyle(
                          color: Color(0xFFBFB2A2),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    final preview = _cameraController;

    if (!_supportsLiveCamera) {
      return const _CameraMessage(
        icon: Icons.phone_android_rounded,
        title: '모바일 카메라가 필요한 기능입니다',
        description: '이 기능은 Android 또는 iPhone에서 실제 카메라를 사용해 스캔합니다.',
      );
    }

    if (_isInitializingCamera) {
      return const _CameraMessage(
        icon: Icons.camera_alt_outlined,
        title: '카메라 준비 중',
        description: '잠시만 기다리면 실시간 스캔 화면이 열립니다.',
        loading: true,
      );
    }

    if (_cameraError != null) {
      return _CameraMessage(
        icon: Icons.error_outline_rounded,
        title: _cameraErrorTitle,
        description: _cameraError!,
      );
    }

    if (!_isCameraReady || preview == null || !preview.value.isInitialized) {
      return const _CameraMessage(
        icon: Icons.no_photography_outlined,
        title: '카메라를 사용할 수 없습니다',
        description: '기기 권한 또는 카메라 상태를 확인해주세요.',
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: preview.value.previewSize?.height ?? 300,
              height: preview.value.previewSize?.width ?? 400,
              child: CameraPreview(preview),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.12),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.24),
                ],
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 220,
            height: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFFFE2B8), width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _initializeCamera() async {
    if (!_supportsLiveCamera) {
      if (mounted) {
        setState(() {
          _isInitializingCamera = false;
          _cameraError = '현재 기기에서는 실시간 카메라 스캔을 사용할 수 없습니다.';
        });
      }
      return;
    }

    if (_isInitializingCamera) {
      return;
    }

    setState(() {
      _isInitializingCamera = true;
      _cameraError = null;
    });

    try {
      await _disposeCamera(resetMessage: false);
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('사용 가능한 카메라가 없습니다.');
      }

      final selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.android
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      _textRecognizer ??= TextRecognizer(script: TextRecognitionScript.korean);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraController = controller;
        _isCameraReady = true;
        _isInitializingCamera = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializingCamera = false;
        _cameraError = '카메라 초기화에 실패했습니다. 권한을 확인해주세요.\n$error';
      });
    }
  }

  Future<void> _toggleScan() async {
    if (_isScanning) {
      return;
    }

    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != AppLifecycleState.resumed) {
      setState(() {
        _cameraError = '앱 화면이 완전히 열린 뒤 다시 시도해주세요.';
      });
      return;
    }

    if (!_isCameraReady || _cameraController == null) {
      setState(() {
        _cameraError = '카메라 준비가 끝난 뒤 다시 시도해주세요.';
      });
      return;
    }

    setState(() {
      _isScanning = true;
      _hasData = true;
      _activeTab = ScanTab.text;
      _cameraError = null;
      _extractedText = '';
      _summary = '';
      _keywords = [];
      _characters = [];
      _chatMessages.clear();
    });

    try {
      await _captureAndAnalyzeFrame();
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = false;
        _cameraError = '페이지 촬영과 분석에 실패했습니다.\n$error';
      });
    }
  }

  Future<void> _captureAndAnalyzeFrame() async {
    final controller = _cameraController;
    final textRecognizer = _textRecognizer;
    if (controller == null || textRecognizer == null) {
      throw Exception('카메라 또는 OCR 준비가 아직 끝나지 않았습니다.');
    }

    if (controller.value.isTakingPicture) {
      return;
    }

    XFile? capturedImage;

    try {
      capturedImage = await controller.takePicture();
      final inputImage = InputImage.fromFilePath(capturedImage.path);
      final recognizedText = await textRecognizer.processImage(inputImage);
      final normalizedText = recognizedText.text.trim();

      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = false;
        _extractedText = normalizedText;
        if (normalizedText.isEmpty) {
          _cameraError = '텍스트를 찾지 못했습니다. 책 페이지를 더 가까이 맞춘 뒤 다시 시도해주세요.';
        }
      });
      await _ensureResultData();
    } finally {
      if (capturedImage != null) {
        unawaited(_deleteTempCapture(capturedImage.path));
      }
    }
  }

  Future<void> _deleteTempCapture(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Temporary camera files can already be gone on some devices.
    }
  }

  String get _cameraErrorTitle {
    final error = _cameraError ?? '';
    if (error.contains('텍스트를 찾지 못했습니다')) {
      return '텍스트를 찾지 못했습니다';
    }
    if (error.contains('앱 화면이 완전히 열린 뒤')) {
      return '잠시 후 다시 시도해주세요';
    }
    if (error.contains('페이지 촬영과 분석에 실패했습니다')) {
      return '페이지 분석에 실패했습니다';
    }
    return '카메라를 열 수 없습니다';
  }

  Future<void> _disposeCamera({bool resetMessage = true}) async {
    final controller = _cameraController;
    _cameraController = null;

    if (mounted) {
      setState(() {
        _isCameraReady = false;
        _isScanning = false;
        _isInitializingCamera = false;
        if (resetMessage) {
          _cameraError = '카메라를 다시 준비하고 있습니다.';
        }
      });
    } else {
      _isCameraReady = false;
      _isScanning = false;
      _isInitializingCamera = false;
    }

    if (controller == null) {
      return;
    }

    try {
      await controller.dispose();
    } catch (_) {
      // Some devices already close the camera when the app goes inactive.
    }
  }

  Future<void> _ensureResultData() async {
    if (!_hasData || _extractedText.trim().isEmpty) {
      return;
    }

    setState(() {
      if (_summary.isEmpty) {
        _summary = _buildSimpleSummary(_extractedText);
      }
      if (_keywords.isEmpty) {
        _keywords = _extractSimpleKeywords(_extractedText);
      }
      if (_characters.isEmpty) {
        _characters = _extractSimpleCharacters(_extractedText);
      }
      if (_chatMessages.isEmpty) {
        _chatMessages.add(
          const _ChatEntry(
            role: ChatRole.assistant,
            content: '실시간 스캔이 끝났습니다. 읽은 내용에서 궁금한 점을 질문해보세요.',
          ),
        );
      }
    });

    final analysis = await _claudeService.analyzeScanText(_extractedText);
    if (!mounted) {
      return;
    }

    setState(() {
      if (analysis != null) {
        if (analysis.summary.isNotEmpty) {
          _summary = analysis.summary;
        }
        if (analysis.keywords.isNotEmpty) {
          _keywords = analysis.keywords;
        }
        if (analysis.characters.isNotEmpty) {
          _characters = analysis.characters
              .where((character) => character.name.isNotEmpty)
              .map(
                (character) => _SimpleCharacter(
                  name: character.name,
                  description: character.description.isEmpty
                      ? 'Claude가 추출한 인물 후보입니다.'
                      : character.description,
                ),
              )
              .toList();
        }
      } else {
        _chatMessages.add(
          const _ChatEntry(
            role: ChatRole.assistant,
            content: 'Claude API가 아직 연결되지 않았거나 응답을 받지 못해 임시 분석 결과를 보여주고 있습니다.',
          ),
        );
      }
    });
  }

  String _buildSimpleSummary(String text) {
    final collapsed = text.replaceAll('\n', ' ').trim();
    if (collapsed.length <= 120) {
      return collapsed;
    }
    return '${collapsed.substring(0, 120).trim()}...';
  }

  List<String> _extractSimpleKeywords(String text) {
    final words = RegExp(r'[A-Za-z가-힣]{2,}')
        .allMatches(text)
        .map((match) => match.group(0)!)
        .where(
          (word) => !{
            '그리고',
            '하지만',
            '그러나',
            '입니다',
            '있는',
            '에서',
            '으로',
            '하면',
            '그는',
            '그녀',
          }.contains(word),
        )
        .take(4)
        .toList();

    if (words.isEmpty) {
      return ['실시간 스캔', 'OCR'];
    }

    return words.toSet().take(4).toList();
  }

  List<_SimpleCharacter> _extractSimpleCharacters(String text) {
    final matches = RegExp(r'[가-힣]{2,4}')
        .allMatches(text)
        .map((match) => match.group(0)!)
        .where((word) => word != '그리고' && word != '하지만' && word != '그러나')
        .take(2)
        .toList();

    return matches
        .map(
          (name) => _SimpleCharacter(
            name: name,
            description: '스캔 텍스트에서 반복적으로 보인 이름 또는 주요 단어입니다.',
          ),
        )
        .toList();
  }

  void _sendMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty) {
      return;
    }

    setState(() {
      _chatMessages.add(_ChatEntry(role: ChatRole.user, content: text));
      _chatController.clear();
    });

    unawaited(_answerScanQuestion(text));
  }

  Future<void> _answerScanQuestion(String question) async {
    final temporaryBook = Book(
      id: 'scan-preview',
      title: '실시간 스캔 기록',
      author: '저자 미상',
      coverUrl:
          'https://images.unsplash.com/photo-1604435062356-a880b007922c?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=1080',
      summary: _summary,
      keywords: _keywords,
      characters: _characters
          .map(
            (character) => Character(
              id: character.name,
              name: character.name,
              role: '스캔 인물',
              description: character.description,
              imageUrl:
                  'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=1080',
            ),
          )
          .toList(),
      relationships: const [],
    );

    final answer = await _claudeService.answerBookQuestion(
      book: temporaryBook,
      question: question,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _chatMessages.add(
        _ChatEntry(
          role: ChatRole.assistant,
          content:
              answer ??
              'Claude API가 아직 연결되지 않았거나 응답을 받지 못했습니다. 나중에 API를 연결하면 더 정확한 답변을 받을 수 있습니다.',
        ),
      );
    });
  }

  void _saveToLibrary(Book? existingBook) {
    final appState = AppStateScope.of(context);
    final totalPages = existingBook?.totalPages ?? 300;
    final nextPage = existingBook == null
        ? Random().nextInt(90) + 1
        : min(
            (existingBook.currentPage ?? 0) + Random().nextInt(30) + 10,
            totalPages,
          );

    final savedBook = Book(
      id: 'b${DateTime.now().millisecondsSinceEpoch}',
      title: existingBook?.title ?? '실시간 스캔 기록',
      author: existingBook?.author ?? '저자 미상',
      coverUrl:
          existingBook?.coverUrl ??
          'https://images.unsplash.com/photo-1604435062356-a880b007922c?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBteXN0ZXJ5fGVufDF8fHx8MTc3Mzc5NDUwM3ww&ixlib=rb-4.1.0&q=80&w=1080',
      summary: _summary,
      keywords: _keywords,
      characters: _characters
          .map(
            (character) => Character(
              id: character.name,
              name: character.name,
              role: '스캔 인물',
              description: character.description,
              imageUrl:
                  'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=1080',
            ),
          )
          .toList(),
      relationships: existingBook?.relationships ?? const [],
      currentPage: nextPage,
      totalPages: totalPages,
      progress: ((nextPage / totalPages) * 100).round(),
    );

    appState.addBook(savedBook);

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BookDetailScreen(bookId: savedBook.id),
      ),
    );
  }
}

enum ScanTab { text, summary, characters, chat }

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class _CameraFrame extends StatelessWidget {
  const _CameraFrame({required this.isScanning, required this.child});

  final bool isScanning;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MediaQuery.of(context).size.width * 0.76,
      constraints: const BoxConstraints(maxWidth: 340),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isScanning ? const Color(0xFFFFC47B) : const Color(0xFF5A4F46),
          width: 2,
        ),
        boxShadow: isScanning
            ? [
                BoxShadow(
                  color: const Color(0xFFFFB55D).withValues(alpha: 0.25),
                  blurRadius: 40,
                  spreadRadius: 10,
                ),
              ]
            : null,
      ),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: Stack(
          children: [
            Positioned.fill(child: child),
            if (isScanning)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: -1, end: 1),
                  duration: const Duration(seconds: 2),
                  curve: Curves.easeInOut,
                  builder: (context, value, scanLine) {
                    return Transform.translate(
                      offset: Offset(0, value * 260),
                      child: scanLine,
                    );
                  },
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFC47B),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFFC47B).withValues(alpha: 0.9),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage({
    required this.icon,
    required this.title,
    required this.description,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.08),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                Icon(icon, color: const Color(0xFFFFD9AD), size: 34),
              const SizedBox(height: 18),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                description,
                style: const TextStyle(color: Color(0xFFD6C9BC), height: 1.5),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({
    required this.activeTab,
    required this.isScanning,
    required this.extractedText,
    required this.summary,
    required this.keywords,
    required this.characters,
    required this.chatMessages,
    required this.chatController,
    required this.onTabSelected,
    required this.onSendMessage,
  });

  final ScanTab activeTab;
  final bool isScanning;
  final String extractedText;
  final String summary;
  final List<String> keywords;
  final List<_SimpleCharacter> characters;
  final List<_ChatEntry> chatMessages;
  final TextEditingController chatController;
  final ValueChanged<ScanTab> onTabSelected;
  final VoidCallback onSendMessage;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: const BoxDecoration(
        color: Color(0xFFFDFBF7),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _ScanTabChip(
                    icon: Icons.menu_book_rounded,
                    label: '텍스트',
                    selected: activeTab == ScanTab.text,
                    onTap: () => onTabSelected(ScanTab.text),
                  ),
                  _ScanTabChip(
                    icon: Icons.auto_awesome_rounded,
                    label: '임시 요약',
                    selected: activeTab == ScanTab.summary,
                    disabled: isScanning,
                    onTap: () => onTabSelected(ScanTab.summary),
                  ),
                  _ScanTabChip(
                    icon: Icons.people_alt_outlined,
                    label: '인물 후보',
                    selected: activeTab == ScanTab.characters,
                    disabled: isScanning,
                    onTap: () => onTabSelected(ScanTab.characters),
                  ),
                  _ScanTabChip(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: '질문하기',
                    selected: activeTab == ScanTab.chat,
                    disabled: isScanning,
                    onTap: () => onTabSelected(ScanTab.chat),
                  ),
                ],
              ),
            ),
          ),
          if (isScanning)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              color: const Color(0xFFFFF4E7),
              child: const Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '카메라 화면을 읽으면서 OCR 텍스트를 갱신하고 있습니다...',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Color(0xFFA46728),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Builder(
                builder: (context) {
                  switch (activeTab) {
                    case ScanTab.text:
                      return Text(
                        extractedText.isEmpty
                            ? '실시간 OCR 결과가 아직 없습니다.'
                            : extractedText,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(height: 1.7),
                      );
                    case ScanTab.summary:
                      if (summary.isEmpty) {
                        return const Text('스캔을 멈추면 텍스트를 바탕으로 임시 요약을 보여줍니다.');
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyLarge?.copyWith(height: 1.7),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: keywords
                                .map(
                                  (keyword) => Chip(label: Text('#$keyword')),
                                )
                                .toList(),
                          ),
                        ],
                      );
                    case ScanTab.characters:
                      if (characters.isEmpty) {
                        return const Text('인물 후보가 아직 없습니다.');
                      }
                      return Column(
                        children: characters
                            .map(
                              (character) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    border: Border.all(
                                      color: const Color(0xFFE4DDD6),
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFFFF4E7),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.person_rounded,
                                          color: Color(0xFFA46728),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              character.name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              character.description,
                                              style: const TextStyle(
                                                height: 1.5,
                                                color: Color(0xFF6F675F),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      );
                    case ScanTab.chat:
                      return SizedBox(
                        height: 280,
                        child: Column(
                          children: [
                            Expanded(
                              child: ListView.separated(
                                itemCount: chatMessages.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final message = chatMessages[index];
                                  return ChatBubble(
                                    role: message.role,
                                    content: message.content,
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: chatController,
                                    minLines: 1,
                                    maxLines: 3,
                                    decoration: const InputDecoration(
                                      hintText: '궁금한 점을 물어보세요.',
                                      filled: true,
                                      fillColor: Colors.white,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(18),
                                        ),
                                        borderSide: BorderSide(
                                          color: Color(0xFFE4DDD6),
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(18),
                                        ),
                                        borderSide: BorderSide(
                                          color: Color(0xFFE4DDD6),
                                        ),
                                      ),
                                    ),
                                    onSubmitted: (_) => onSendMessage(),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: onSendMessage,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFD58C40),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.all(16),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                  ),
                                  child: const Icon(Icons.send_rounded),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanTabChip extends StatelessWidget {
  const _ScanTabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = disabled
        ? const Color(0xFFC6BBB0)
        : selected
        ? const Color(0xFF8A4B17)
        : const Color(0xFF6F675F);

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFFF0D9) : const Color(0xFFF5F1EA),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SimpleCharacter {
  const _SimpleCharacter({required this.name, required this.description});

  final String name;
  final String description;
}

class _ChatEntry {
  const _ChatEntry({required this.role, required this.content});

  final ChatRole role;
  final String content;
}
