import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

/// 발표 데모용 외부 대시보드 — 앱 안에 작은 HTTP 서버를 띄워, 같은 네트워크의
/// 노트북 브라우저에서 8칸(4행×2열) OCR 진행 상황을 실시간으로 본다.
///   · 칸별 캡처 이미지 들어오면 → 해당 위치에 썸네일 표시
///   · 8칸 모여 OCR 완료 → 이미지가 OCR 텍스트로 교체
///   · 페이지 리셋 시 → 빈 칸으로 초기화
class DemoDashboardService {
  /// 바인딩할 포트(고정 8080).
  static const int port = 8080;
  static const int _cellCount = 8;

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  // 셀별 현재 상태 — 둘 다 null이면 빈 칸. 이미지가 들어오면 _images에,
  // OCR 결과로 교체되면 _texts에 저장(이미지는 비움).
  final List<Uint8List?> _images = List.filled(_cellCount, null);
  final List<String?> _texts = List.filled(_cellCount, null);
  // 전체 OCR 결과(합쳐진 본문) / 한 장 전체 사진. 8셀이 다 모인 뒤 합쳐진 텍스트나,
  // 8셀 없이 한 장으로 통째 OCR한 결과를 여기 보관. 클라이언트에서 "전체 OCR" 버튼/모드로 본다.
  String? _fullText;
  Uint8List? _fullImage;
  String? _publicUrl;

  String? get url => _publicUrl;
  bool get isRunning => _server != null;

  /// 서버를 시작하고 접속 URL을 돌려준다. 이미 떠 있으면 그대로 URL만 반환.
  Future<String?> start() async {
    if (_server != null) return _publicUrl;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _publicUrl = await _detectUrl();
      debugPrint("📺 데모 대시보드 시작: $_publicUrl");
      _server!.listen(_handleRequest);
      return _publicUrl;
    } catch (e) {
      debugPrint("📺 데모 대시보드 시작 실패: $e");
      _server = null;
      _publicUrl = null;
      return null;
    }
  }

  Future<String> _detectUrl() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      // 우선순위 1: 사설망 IP(192.168.x, 10.x, 172.16~31.x) — 노트북이 접속 가능.
      // 우선순위 2: 그 외 IPv4(셀룰러 NAT 192.0.0.x 같은 비-접근 IP 대비책).
      // 인터페이스 이름이 'wlan'/'eth'면 추가 가산점.
      String? lanCandidate;
      String? fallback;
      for (final ni in interfaces) {
        final niName = ni.name.toLowerCase();
        final preferred = niName.startsWith('wlan') || niName.startsWith('eth');
        for (final addr in ni.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          final ip = addr.address;
          final isPrivate = _isPrivateLan(ip);
          if (isPrivate) {
            // 사설망이면 wlan/eth 우선, 그렇지 않으면 처음 발견한 사설망.
            if (preferred) return 'http://$ip:$port';
            lanCandidate ??= ip;
          } else {
            fallback ??= ip;
          }
        }
      }
      if (lanCandidate != null) return 'http://$lanCandidate:$port';
      if (fallback != null) return 'http://$fallback:$port';
    } catch (_) {}
    return 'http://localhost:$port';
  }

  bool _isPrivateLan(String ip) {
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('172.')) {
      final second = int.tryParse(ip.split('.')[1]);
      if (second != null && second >= 16 && second <= 31) return true;
    }
    return false;
  }

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    if (path == '/' || path == '/index.html') {
      _serveHtml(request);
    } else if (path == '/ws') {
      _handleWebSocket(request);
    } else if (path.startsWith('/cell/')) {
      _serveCellImage(request);
    } else if (path == '/full.jpg') {
      _serveFullImage(request);
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }

  void _serveFullImage(HttpRequest request) {
    if (_fullImage == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('image', 'jpeg')
      ..headers.set('Cache-Control', 'no-store')
      ..add(_fullImage!)
      ..close();
  }

  void _serveHtml(HttpRequest request) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..write(_htmlPage)
      ..close();
  }

  void _serveCellImage(HttpRequest request) {
    final segs = request.uri.pathSegments;
    if (segs.length != 2) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    final idxStr = segs[1].replaceAll('.jpg', '');
    final idx = int.tryParse(idxStr);
    if (idx == null ||
        idx < 0 ||
        idx >= _cellCount ||
        _images[idx] == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('image', 'jpeg')
      ..headers.set('Cache-Control', 'no-store')
      ..add(_images[idx]!)
      ..close();
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    try {
      final ws = await WebSocketTransformer.upgrade(request);
      _clients.add(ws);
      _sendSnapshot(ws);
      ws.listen(
        (_) {},
        onDone: () => _clients.remove(ws),
        onError: (_) => _clients.remove(ws),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint("📺 WebSocket upgrade 실패: $e");
    }
  }

  void _sendSnapshot(WebSocket ws) {
    // 접속 직후 현재 8칸의 상태를 한 번에 보내준다.
    // 이미지/텍스트는 독립적으로 가질 수 있다(이미지 있고 텍스트도 있음 = 클릭 토글 가능).
    ws.add(jsonEncode({'type': 'reset'}));
    for (int i = 0; i < _cellCount; i++) {
      try {
        if (_images[i] != null) {
          ws.add(jsonEncode({'cell': i, 'type': 'image'}));
        }
        if (_texts[i] != null) {
          ws.add(jsonEncode({'cell': i, 'type': 'text', 'text': _texts[i]}));
        }
      } catch (_) {}
    }
    if (_fullText != null || _fullImage != null) {
      ws.add(jsonEncode({
        'type': 'fullPage',
        'hasImage': _fullImage != null,
        'text': _fullText ?? '',
      }));
    }
  }

  void _broadcast(Map<String, dynamic> msg) {
    final data = jsonEncode(msg);
    final dead = <WebSocket>[];
    for (final ws in _clients) {
      try {
        ws.add(data);
      } catch (_) {
        dead.add(ws);
      }
    }
    for (final ws in dead) {
      _clients.remove(ws);
    }
  }

  /// 셀 [idx]에 새 캡처 이미지를 표시한다. 새 이미지는 새 페이지의 캡처를 뜻하므로
  /// 이전 텍스트(=이전 페이지의 OCR)는 지운다.
  void pushImage(int idx, Uint8List bytes) {
    if (idx < 0 || idx >= _cellCount) return;
    _images[idx] = bytes;
    _texts[idx] = null;
    _broadcast({'cell': idx, 'type': 'image'});
  }

  /// 셀 [idx]의 OCR 텍스트를 저장한다. 이미지는 *지우지 않는다* — 브라우저에서
  /// 사용자가 셀을 클릭하면 이미지↔텍스트로 토글된다.
  void pushText(int idx, String text) {
    if (idx < 0 || idx >= _cellCount) return;
    _texts[idx] = text;
    // _images[idx]는 유지 — 클릭 토글 보기를 위해 둘 다 보관.
    _broadcast({'cell': idx, 'type': 'text', 'text': text});
  }

  /// 전체 OCR 결과를 한 번에 push. image가 있으면(=한 장으로 전체 OCR한 케이스)
  /// 클라이언트는 자동으로 전체 모드로 전환하고 사진+텍스트 토글을 보여준다.
  /// image가 null이면(=8칸 합친 케이스) 텍스트만 보관하고 모드 전환은 하지 않음.
  /// 호출 시 이전 fullImage는 항상 갱신됨 — 이전 페이지 사진이 남는 문제 방지.
  void pushFullPage({Uint8List? image, required String text}) {
    _fullImage = image;
    _fullText = text;
    _broadcast({
      'type': 'fullPage',
      'hasImage': image != null,
      'text': text,
    });
  }

  /// 모든 셀을 빈 칸으로 초기화(새 페이지 시작 시).
  void reset() {
    for (int i = 0; i < _cellCount; i++) {
      _images[i] = null;
      _texts[i] = null;
    }
    _fullText = null;
    _fullImage = null;
    _broadcast({'type': 'reset'});
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _publicUrl = null;
    for (final ws in List<WebSocket>.from(_clients)) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _clients.clear();
  }

  // 노트북 브라우저가 받는 한 페이지짜리 HTML(인라인 CSS·JS).
  // 각 셀은 이미지·텍스트를 *모두* 보관할 수 있고, 텍스트가 있는 셀을 클릭하면
  // 이미지↔텍스트로 토글된다.
  static const String _htmlPage = '''
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Readassi · OCR 8칸 라이브</title>
  <style>
    :root { --bg:#1a1a1a; --panel:#262626; --border:#3a3a3a; --muted:#888;
      --fg:#eee; --accent:#69f0ae; --warn:#ffd180; --info:#82b1ff; }
    * { box-sizing: border-box; }
    body { font-family: -apple-system, "Segoe UI", "Apple SD Gothic Neo",
      "Malgun Gothic", sans-serif; margin: 0; padding: 16px; background: var(--bg);
      color: var(--fg); }
    header { display: flex; align-items: baseline; gap: 14px; margin-bottom: 10px;
      flex-wrap: wrap; }
    header h1 { font-size: 18px; margin: 0; }
    #status { font-size: 12px; color: var(--muted); }
    #status.ok { color: var(--accent); }
    #status.bad { color: #ff8a80; }
    .legend { font-size: 11px; color: var(--muted); margin-left: auto; }
    .grid { display: grid; grid-template-columns: 1fr 1fr;
      grid-template-rows: repeat(4, 1fr); gap: 8px;
      height: calc(100vh - 70px); }
    .cell { background: var(--panel); border: 2px solid var(--border);
      border-radius: 8px; padding: 8px; display: flex; flex-direction: column;
      overflow: hidden; position: relative; transition: border-color 0.2s; }
    .cell-label { font-size: 11px; color: var(--muted); margin-bottom: 4px;
      font-weight: 600; display: flex; justify-content: space-between;
      align-items: center; }
    .cell-hint { font-size: 10px; color: var(--info); opacity: 0; transition: opacity 0.2s; }
    .cell.has-both .cell-hint { opacity: 1; }
    .cell.has-both { cursor: pointer; }
    .cell.has-both:hover { border-color: var(--info); }
    .cell-body { flex: 1; display: flex; align-items: center;
      justify-content: center; overflow: hidden; min-height: 0; }
    .cell-body img { max-width: 100%; max-height: 100%; object-fit: contain;
      border-radius: 4px; }
    .cell-body pre { font-size: 12px; line-height: 1.45; color: var(--fg);
      white-space: pre-wrap; word-wrap: break-word; margin: 0; padding: 0;
      max-height: 100%; overflow: auto; width: 100%;
      font-family: ui-monospace, "Cascadia Code", Consolas, monospace; }
    .cell-empty { color: #555; font-size: 12px; }
    .cell.has-image { border-color: var(--warn); }
    .cell.has-both { border-color: var(--accent); }
    .cell.view-text { border-color: var(--info); }
    button.toggle { background: var(--panel); color: var(--fg); border: 1px solid var(--border);
      padding: 6px 12px; border-radius: 6px; font-size: 12px; cursor: pointer;
      transition: all 0.15s; }
    button.toggle:hover { border-color: var(--info); color: var(--info); }
    button.toggle.active { background: var(--info); color: var(--bg); border-color: var(--info); }
    button.toggle:disabled { opacity: 0.4; cursor: not-allowed; }
    #full-panel { display: none; height: calc(100vh - 70px); background: var(--panel);
      border: 2px solid var(--border); border-radius: 8px; padding: 12px; overflow: hidden;
      flex-direction: column; }
    #full-panel.show { display: flex; }
    .grid.hide { display: none; }
    #full-body { flex: 1; display: flex; align-items: center; justify-content: center;
      overflow: hidden; min-height: 0; }
    #full-body img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 4px; }
    #full-body pre { font-size: 13px; line-height: 1.55; color: var(--fg); white-space: pre-wrap;
      word-wrap: break-word; margin: 0; padding: 0; max-height: 100%; overflow: auto; width: 100%;
      font-family: ui-monospace, "Cascadia Code", Consolas, monospace; }
    #full-meta { font-size: 11px; color: var(--muted); margin-bottom: 6px; display: flex;
      justify-content: space-between; align-items: center; }
    #full-hint { font-size: 10px; color: var(--info); }
  </style>
</head>
<body>
  <header>
    <h1>📚 OCR 8칸 라이브</h1>
    <span id="status">연결 중…</span>
    <button id="btn-full" class="toggle" disabled>📄 전체 OCR 보기</button>
    <span class="legend">⬜ 빈 칸 · 🟡 이미지 수집 · 🟢 OCR 완료(클릭=텍스트) · 🔵 텍스트 보기</span>
  </header>
  <div class="grid" id="grid"></div>
  <div id="full-panel">
    <div id="full-meta"><span id="full-title">📄 전체 OCR</span><span id="full-hint">🔁 클릭=토글</span></div>
    <div id="full-body"></div>
  </div>
  <script>
    const labels = ['1행 좌','1행 우','2행 좌','2행 우','3행 좌','3행 우','4행 좌','4행 우'];
    const grid = document.getElementById('grid');
    const status = document.getElementById('status');
    const cells = [];
    // 셀별 상태: hasImage, text(null이면 없음), view('image'|'text')
    const state = [];
    for (let i = 0; i < 8; i++) {
      const cell = document.createElement('div');
      cell.className = 'cell';
      cell.innerHTML =
        '<div class="cell-label"><span>' + labels[i] + '</span>' +
        '<span class="cell-hint">🔁 클릭=텍스트</span></div>' +
        '<div class="cell-body"><span class="cell-empty">(빈 칸)</span></div>';
      grid.appendChild(cell);
      cells.push(cell);
      state.push({ hasImage: false, text: null, view: 'image' });
      const idx = i;
      cell.addEventListener('click', () => toggleCell(idx));
    }
    function escapeHtml(s) {
      return (s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }
    function setImage(idx) {
      // 새 이미지는 새 캡처를 뜻하므로 이전 텍스트를 비운다.
      state[idx].hasImage = true;
      state[idx].text = null;
      state[idx].view = 'image';
      render(idx);
    }
    function setText(idx, text) {
      // 텍스트가 들어오면 이미지는 유지 — 클릭으로 토글 가능.
      state[idx].text = text;
      // 새로 OCR이 들어오면 자동으로 이미지 보기로 두고, 사용자가 클릭해서 텍스트 보게.
      render(idx);
    }
    function toggleCell(idx) {
      const s = state[idx];
      if (s.text === null) return; // 텍스트 없으면 토글할 게 없음
      if (!s.hasImage) return;     // 이미지 없으면 그냥 텍스트만 보이는 상태
      s.view = s.view === 'image' ? 'text' : 'image';
      render(idx);
    }
    function clearAll() {
      for (let i = 0; i < 8; i++) {
        state[i] = { hasImage: false, text: null, view: 'image' };
        render(i);
      }
      fullState.hasImage = false;
      fullState.text = null;
      fullState.view = 'image';
      // 새 세션 시작 — 전체 모드면 8분할로 자동 복귀.
      if (fullState.shown) {
        fullState.shown = false;
        fullPanel.classList.remove('show');
        gridEl.classList.remove('hide');
      }
      updateFullButton();
      renderFull();
    }
    // 전체 OCR 상태(8칸 합쳐진 본문 또는 한 장 캡처 + 텍스트)
    const fullState = { hasImage: false, text: null, view: 'image', shown: false };
    const btnFull = document.getElementById('btn-full');
    const fullPanel = document.getElementById('full-panel');
    const fullBody = document.getElementById('full-body');
    const fullTitle = document.getElementById('full-title');
    const gridEl = document.getElementById('grid');
    function updateFullButton() {
      const has = fullState.hasImage || fullState.text !== null;
      btnFull.disabled = !has;
      btnFull.classList.toggle('active', fullState.shown);
      btnFull.textContent = fullState.shown ? '🔲 8칸 보기' : '📄 전체 OCR 보기';
    }
    btnFull.addEventListener('click', () => {
      if (btnFull.disabled) return;
      fullState.shown = !fullState.shown;
      fullPanel.classList.toggle('show', fullState.shown);
      gridEl.classList.toggle('hide', fullState.shown);
      updateFullButton();
      renderFull();
    });
    fullBody.addEventListener('click', () => {
      // 전체 모드 안에서 이미지↔텍스트 토글
      if (!fullState.shown) return;
      if (fullState.text === null) return;
      if (!fullState.hasImage) return;
      fullState.view = fullState.view === 'image' ? 'text' : 'image';
      renderFull();
    });
    // 전체 OCR 결과(8칸 합친 텍스트 또는 한 장 전체 캡처) 한 번에 갱신.
    // hasImage=true이면 한 장 전체 OCR 케이스로 보고 자동 전체 모드 전환.
    // hasImage=false이면 8칸 합친 텍스트 — 모드 전환은 안 하고 버튼만 활성화.
    function setFullPage(hasImage, text) {
      fullState.hasImage = hasImage;
      fullState.text = (text === '' ? null : (text || null));
      fullState.view = hasImage ? 'image' : 'text';
      if (hasImage && !fullState.shown) {
        // 자동 전체 모드 진입 — 한 장으로 전체 OCR된 경우만.
        fullState.shown = true;
        fullPanel.classList.add('show');
        gridEl.classList.add('hide');
      }
      updateFullButton();
      renderFull();
    }
    function renderFull() {
      if (fullState.hasImage && (fullState.view === 'image' || fullState.text === null)) {
        fullTitle.textContent = '📄 전체 페이지 (사진)';
        fullBody.innerHTML = '<img src="/full.jpg?t=' + Date.now() + '">';
      } else if (fullState.text !== null) {
        fullTitle.textContent = '📄 전체 OCR (텍스트)';
        fullBody.innerHTML = '<pre>' +
          (fullState.text.trim() ? escapeHtml(fullState.text) : '(빈 텍스트)') + '</pre>';
      } else {
        fullTitle.textContent = '📄 전체 OCR';
        fullBody.innerHTML = '<span class="cell-empty">(아직 결과 없음)</span>';
      }
    }
    updateFullButton();
    function render(idx) {
      const s = state[idx];
      const c = cells[idx];
      const body = c.querySelector('.cell-body');
      c.classList.remove('has-image','has-both','view-text');
      if (!s.hasImage && s.text === null) {
        body.innerHTML = '<span class="cell-empty">(빈 칸)</span>';
        return;
      }
      if (s.view === 'text' && s.text !== null) {
        c.classList.add('view-text');
        body.innerHTML = '<pre>' +
          (s.text.trim() ? escapeHtml(s.text) : '(빈 텍스트)') + '</pre>';
        return;
      }
      // 이미지 보기 모드
      if (s.hasImage) {
        if (s.text !== null) c.classList.add('has-both');
        else c.classList.add('has-image');
        body.innerHTML = '<img src="/cell/' + idx + '.jpg?t=' + Date.now() + '">';
      } else if (s.text !== null) {
        // 이미지 없이 텍스트만(드문 케이스) — 그냥 텍스트 표시.
        c.classList.add('view-text');
        body.innerHTML = '<pre>' +
          (s.text.trim() ? escapeHtml(s.text) : '(빈 텍스트)') + '</pre>';
      }
    }
    function connect() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const ws = new WebSocket(proto + '//' + location.host + '/ws');
      ws.onopen = () => { status.textContent = '연결됨'; status.className = 'ok'; };
      ws.onclose = () => {
        status.textContent = '연결 끊김 — 1.5초 후 재시도'; status.className = 'bad';
        setTimeout(connect, 1500);
      };
      ws.onerror = () => { status.textContent = '오류'; status.className = 'bad'; };
      ws.onmessage = (ev) => {
        try {
          const msg = JSON.parse(ev.data);
          if (msg.type === 'reset') clearAll();
          else if (msg.type === 'image') setImage(msg.cell);
          else if (msg.type === 'text') setText(msg.cell, msg.text);
          else if (msg.type === 'fullPage') setFullPage(!!msg.hasImage, msg.text);
        } catch (e) {}
      };
    }
    connect();
  </script>
</body>
</html>
''';
}
