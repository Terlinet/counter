import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

enum CameraStatus { loading, available, denied, error }

class ObjectCountingScreen extends StatefulWidget {
  const ObjectCountingScreen({super.key});

  @override
  State<ObjectCountingScreen> createState() => _ObjectCountingScreenState();
}

class _ObjectCountingScreenState extends State<ObjectCountingScreen> {
  html.VideoElement? _videoElement;
  html.MediaStream? _mediaStream;
  html.DivElement? _videoContainer;
  CameraStatus _cameraStatus = CameraStatus.loading;

  bool _modelReady = false;
  String _statusMessage = "INITIALIZING CORE...";
  String _currentLocation = "DETECTING...";
  String _facingMode = 'environment';
  List<Detection> _detections = [];
  final Map<String, int> _counts = {
    'person': 0, 'car': 0, 'bicycle': 0, 'motorcycle': 0,
  };

  int? _animationFrameId;
  bool _isDetecting = false;
  double _videoWidth = 640;
  double _videoHeight = 480;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory('video-view', (int viewId) {
      _videoContainer = html.DivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = 'black';
      return _videoContainer!;
    });
    _initCamera();
    _loadModel();
    _determinePosition();
  }

  @override
  void dispose() {
    _stopDetectionLoop();
    _stopCamera();
    super.dispose();
  }

  Future<void> _determinePosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 5),
      );
      setState(() => _currentLocation = "${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}");
    } catch (e) {
      setState(() => _currentLocation = "NOT DETECTED");
    }
  }

  void _downloadReport() {
    final now = DateTime.now();
    final report = "TERLINET REPORT\nTIMESTAMP: ${DateFormat('dd/MM/yyyy HH:mm:ss').format(now)}\nLOC: $_currentLocation\n"
        "PEOPLE: ${_counts['person']}\nCARS: ${_counts['car']}\nBIKES: ${_counts['bicycle']}\nMOTOS: ${_counts['motorcycle']}";
    final blob = html.Blob([report.codeUnits], 'text/plain');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)..setAttribute("download", "REPORT_${now.millisecondsSinceEpoch}.txt")..click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> _initCamera() async {
    try {
      final stream = await html.window.navigator.mediaDevices!.getUserMedia({
        'video': {'facingMode': _facingMode, 'width': {'ideal': 1280}, 'height': {'ideal': 720}},
        'audio': false
      });
      _mediaStream = stream;
      _videoElement = html.VideoElement()
        ..id = 'counting-video'
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.transform = _facingMode == 'user' ? 'scaleX(-1)' : 'none'
        ..srcObject = stream;

      await _videoElement!.onCanPlayThrough.first;
      _videoElement!.play();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_videoContainer != null) {
          _videoContainer!.children.clear();
          _videoContainer!.append(_videoElement!);
        }
      });

      setState(() => _cameraStatus = CameraStatus.available);
    } catch (e) {
      setState(() => _cameraStatus = CameraStatus.error);
    }
  }

  void _stopCamera() {
    _mediaStream?.getTracks().forEach((t) => t.stop());
    _videoElement?.remove();
  }

  Future<void> _loadModel() async {
    try {
      if (!mounted) return;
      setState(() => _statusMessage = "WAKING UP NEURAL CORE...");
      Completer<void> completer = Completer();

      html.window.addEventListener('mediapipe-ready', (_) => completer.complete());
      html.window.addEventListener('mediapipe-error', (_) => completer.completeError("FAIL"));

      js.context.callMethod('initObjectDetector');
      await completer.future.timeout(const Duration(seconds: 45));

      if (mounted) {
        setState(() { _modelReady = true; _statusMessage = "SCANNING ACTIVE"; });
        _startDetectionLoop();
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = "IA ERROR - TAP TO RETRY");
    }
  }

  void _startDetectionLoop() {
    void frame(num _) {
      _runDetection();
      _animationFrameId = html.window.requestAnimationFrame(frame);
    }
    _animationFrameId = html.window.requestAnimationFrame(frame);
  }

  void _stopDetectionLoop() {
    if (_animationFrameId != null) html.window.cancelAnimationFrame(_animationFrameId!);
  }

  Future<void> _runDetection() async {
    if (!_modelReady || _isDetecting || _videoElement == null) return;
    _isDetecting = true;

    try {
      if (_videoElement!.videoWidth > 0) {
        _videoWidth = _videoElement!.videoWidth.toDouble();
        _videoHeight = _videoElement!.videoHeight.toDouble();
      }

      // Passamos o elemento de vídeo DIRETAMENTE para o JS
      final result = js.context.callMethod('runObjectDetection', [_videoElement]);
      if (result == null) return;

      final predictions = result as List<dynamic>;
      final List<Detection> detections = [];
      final newCounts = {'person': 0, 'car': 0, 'bicycle': 0, 'motorcycle': 0};

      for (var pred in predictions) {
        final label = pred['class'];
        if (newCounts.containsKey(label)) {
          newCounts[label] = newCounts[label]! + 1;
          final bbox = pred['bbox'] as List<dynamic>;
          detections.add(Detection(
            label: label,
            confidence: (pred['score'] as num).toDouble(),
            rect: Rect.fromLTWH((bbox[0] as num).toDouble(), (bbox[1] as num).toDouble(), (bbox[2] as num).toDouble(), (bbox[3] as num).toDouble()),
          ));
        }
      }

      if (mounted) setState(() { _detections = detections; _counts.addAll(newCounts); });
    } finally {
      _isDetecting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_cameraStatus == CameraStatus.available) Positioned.fill(child: HtmlElementView(viewType: 'video-view')),
          const ScanlineOverlay(),
          if (_detections.isNotEmpty) Positioned.fill(child: CustomPaint(painter: DetectionPainter(_detections, MediaQuery.of(context).size, _videoWidth, _videoHeight, isMirrored: _facingMode == 'user'))),
          _buildHUD(),
          _buildTopBar(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 60, left: 20, right: 20,
      child: Row(
        children: [
          Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            _countCard("PESSOAS", _counts['person']!, Icons.person),
            const SizedBox(width: 8),
            _countCard("CARROS", _counts['car']!, Icons.directions_car),
          ]))),
          IconButton(icon: const Icon(Icons.download, color: Colors.cyanAccent), onPressed: _downloadReport),
        ],
      ),
    );
  }

  Widget _countCard(String l, int c, IconData i) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.orangeAccent)),
      child: Row(children: [Icon(i, color: Colors.cyanAccent, size: 16), const SizedBox(width: 5), Text("$l: $c", style: GoogleFonts.orbitron(color: Colors.white, fontSize: 10))]),
    );
  }

  Widget _buildHUD() {
    return Positioned(bottom: 20, left: 20, right: 20, child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.cyanAccent)), child: Text(_statusMessage, style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 10))));
  }
}

class Detection {
  final String label; final double confidence; final Rect rect;
  Detection({required this.label, required this.confidence, required this.rect});
}

class DetectionPainter extends CustomPainter {
  final List<Detection> detections; final Size screenSize; final double videoWidth; final double videoHeight; final bool isMirrored;
  DetectionPainter(this.detections, this.screenSize, this.videoWidth, this.videoHeight, {this.isMirrored = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (videoWidth == 0) return;
    double scale = (screenSize.width / screenSize.height > videoWidth / videoHeight) ? screenSize.width / videoWidth : screenSize.height / videoHeight;
    double offX = (screenSize.width - videoWidth * scale) / 2;
    double offY = (screenSize.height - videoHeight * scale) / 2;
    final paint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.stroke..strokeWidth = 2;

    for (var det in detections) {
      double l = det.rect.left * scale + offX;
      double t = det.rect.top * scale + offY;
      double w = det.rect.width * scale;
      double h = det.rect.height * scale;
      if (isMirrored) l = screenSize.width - l - w;
      canvas.drawRect(Rect.fromLTWH(l, t, w, h), paint);
    }
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ScanlineOverlay extends StatelessWidget {
  const ScanlineOverlay({super.key});
  @override Widget build(BuildContext context) => IgnorePointer(child: ListView.builder(itemCount: 100, itemBuilder: (context, i) => Container(height: 4, color: i % 2 == 0 ? Colors.white.withOpacity(0.02) : Colors.transparent)));
}
