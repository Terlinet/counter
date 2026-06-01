import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart' as mlkit;
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:universal_html/html.dart' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

class AreaCountingScreen extends StatefulWidget {
  const AreaCountingScreen({super.key});

  @override
  State<AreaCountingScreen> createState() => _AreaCountingScreenState();
}

class _AreaCountingScreenState extends State<AreaCountingScreen> {
  // --- Common State ---
  String _statusMessage = "INITIALIZING AREA MODE...";
  String _processingTime = '0ms';
  String _fps = '0';
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  Timer? _reportTimer;

  // ROI Points (Normalized 0.0 to 1.0)
  List<Offset> _roiPoints = [
    const Offset(0.2, 0.2),
    const Offset(0.8, 0.2),
    const Offset(0.8, 0.8),
    const Offset(0.2, 0.8),
  ];

  final Map<String, int> _counts = {
    'person': 0,
    'car': 0,
    'bicycle': 0,
    'motorcycle': 0,
    'dog': 0,
    'cat': 0,
    'bird': 0,
  };

  // --- Mobile State ---
  CameraController? _cameraController;
  mlkit.ObjectDetector? _objectDetector;
  bool _isDetecting = false;
  List<mlkit.DetectedObject> _detectedObjects = [];

  // --- Web State ---
  html.VideoElement? _videoElement;
  bool _modelReady = false;
  List<dynamic> _webDetections = [];
  Timer? _detectionTimer;
  String _webFacingMode = 'environment';

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _initWeb();
    } else {
      _initMobile();
    }
    _reportTimer = Timer.periodic(const Duration(seconds: 15), (timer) => _sendDataToServer());
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _detectionTimer?.cancel();
    _cameraController?.dispose();
    _objectDetector?.close();
    super.dispose();
  }

  // ========================== ROI LOGIC ==========================
  bool _isPointInPolygon(Offset p, List<Offset> polygon) {
    bool isInside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      if ((polygon[i].dy > p.dy) != (polygon[j].dy > p.dy) &&
          (p.dx < (polygon[j].dx - polygon[i].dx) * (p.dy - polygon[i].dy) / (polygon[j].dy - polygon[i].dy) + polygon[i].dx)) {
        isInside = !isInside;
      }
      j = i;
    }
    return isInside;
  }

  // ========================== WEB LOGIC ==========================
  void _initWeb() {
    ui_web.platformViewRegistry.registerViewFactory('video-area-view', (int viewId) {
      _videoElement = html.VideoElement()
        ..id = 'area-video'
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover';
      return _videoElement!;
    });
    _startWebCamera();
    _loadWebModel();
  }

  Future<void> _startWebCamera() async {
    try {
      final stream = await html.window.navigator.mediaDevices?.getUserMedia({
        'video': {'facingMode': _webFacingMode},
        'audio': false
      });
      if (_videoElement != null && stream != null) _videoElement!.srcObject = stream;
    } catch (e) {
      setState(() => _statusMessage = "WEB CAM ERROR");
    }
  }

  void _loadWebModel() {
    html.window.addEventListener('mediapipe-ready', (_) {
      if (mounted) {
        setState(() {
          _modelReady = true;
          _statusMessage = "AREA SCANNER ACTIVE";
        });
        _startWebLoop();
      }
    });
    js.context.callMethod('initObjectDetectorV3');
  }

  void _startWebLoop() {
    _detectionTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (!mounted || !_modelReady) return;
      final result = js.context.callMethod('runObjectDetection', ['area-video']);
      if (result != null) {
        final predictions = result as List<dynamic>;
        Map<String, int> frameCounts = {};
        for (var p in predictions) {
          final bbox = p['bbox'] as List<dynamic>;
          final label = p['class'].toString().toLowerCase();
          final score = (p['score'] as num).toDouble();

          // Centro do objeto (Normalizado se o MediaPipe retornar valores absolutos?
          // O MediaPipe retorna pixels no video, precisamos converter ou o script ja envia normalizado)
          // Assumindo pixels. Precisamos da largura/altura do video.
          double vw = _videoElement?.videoWidth.toDouble() ?? 1;
          double vh = _videoElement?.videoHeight.toDouble() ?? 1;
          Offset center = Offset(
            (bbox[0] + bbox[2] / 2) / vw,
            (bbox[1] + bbox[3] / 2) / vh
          );

          if (score > 0.4 && _isPointInPolygon(center, _roiPoints)) {
            frameCounts[label] = (frameCounts[label] ?? 0) + 1;
          }
        }
        if (mounted) {
          setState(() {
            _webDetections = predictions;
            _counts.updateAll((key, value) => frameCounts[key] ?? 0);
            _updateFPS();
          });
        }
      }
    });
  }

  // ========================== MOBILE LOGIC ==========================
  Future<void> _initMobile() async {
    _objectDetector = mlkit.ObjectDetector(options: mlkit.ObjectDetectorOptions(
      mode: mlkit.DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    ));
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    _cameraController = CameraController(cameras.first, ResolutionPreset.medium, enableAudio: false);
    await _cameraController!.initialize();
    _cameraController!.startImageStream(_processMobileImage);
    setState(() => _statusMessage = "MOBILE AREA ACTIVE");
  }

  void _processMobileImage(CameraImage image) async {
    if (_isDetecting || _objectDetector == null) return;
    _isDetecting = true;
    final startTime = DateTime.now();
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage != null) {
        final objects = await _objectDetector!.processImage(inputImage);
        Map<String, int> frameCounts = {};
        for (var obj in objects) {
          if (obj.labels.isNotEmpty) {
            String label = obj.labels.first.text.toLowerCase();
            // Centro normalizado
            Offset center = Offset(
              (obj.boundingBox.left + obj.boundingBox.width / 2) / image.height, // Rotacionado
              (obj.boundingBox.top + obj.boundingBox.height / 2) / image.width
            );
            if (_isPointInPolygon(center, _roiPoints)) {
              frameCounts[label] = (frameCounts[label] ?? 0) + 1;
            }
          }
        }
        if (mounted) {
          setState(() {
            _detectedObjects = objects;
            _counts.updateAll((key, value) => frameCounts[key] ?? 0);
            _processingTime = '${DateTime.now().difference(startTime).inMilliseconds}ms';
            _updateFPS();
          });
        }
      }
    } finally {
      _isDetecting = false;
    }
  }

  mlkit.InputImage? _inputImageFromCameraImage(CameraImage image) {
    final sensorOrientation = _cameraController!.description.sensorOrientation;
    mlkit.InputImageRotation? rotation = mlkit.InputImageRotationValue.fromRawValue(sensorOrientation);
    if (rotation == null) return null;
    final format = mlkit.InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final plane = image.planes.first;
    return mlkit.InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: mlkit.InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // ========================== COMMON ==========================
  void _updateFPS() {
    _frameCount++;
    final now = DateTime.now();
    if (_lastFpsUpdate == null || now.difference(_lastFpsUpdate!).inSeconds >= 1) {
      _fps = _frameCount.toString();
      _frameCount = 0;
      _lastFpsUpdate = now;
    }
  }

  Future<void> _switchCamera() async {
    if (kIsWeb) {
      _webFacingMode = (_webFacingMode == 'environment') ? 'user' : 'environment';
      final stream = _videoElement?.srcObject as html.MediaStream?;
      stream?.getTracks().forEach((t) => t.stop());
      await _startWebCamera();
    } else {
      final cameras = await availableCameras();
      int idx = cameras.indexOf(_cameraController!.description) + 1;
      if (idx >= cameras.length) idx = 0;
      await _cameraController!.dispose();
      _cameraController = CameraController(cameras[idx], ResolutionPreset.medium, enableAudio: false);
      await _cameraController!.initialize();
      _cameraController!.startImageStream(_processMobileImage);
      setState(() {});
    }
  }

  void _downloadReport() {
    final report = "TERLINET AREA REPORT\nDATE: ${DateTime.now()}\nCOUNTS: $_counts";
    if (kIsWeb) {
      final blob = html.Blob([utf8.encode(report)], 'text/plain');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)..setAttribute("download", "AREA_REPORT.txt")..click();
      html.Url.revokeObjectUrl(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("REPORT READY")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (kIsWeb) const HtmlElementView(viewType: 'video-area-view')
          else if (_cameraController != null && _cameraController!.value.isInitialized) CameraPreview(_cameraController!),

          const ScanlineOverlay(),

          // Polygon Editor
          GestureDetector(
            onPanUpdate: (details) {
              RenderBox box = context.findRenderObject() as RenderBox;
              Offset local = box.globalToLocal(details.globalPosition);
              Offset normalized = Offset(local.dx / box.size.width, local.dy / box.size.height);

              int? closestIdx;
              double minCDist = 0.05;
              for (int i = 0; i < _roiPoints.length; i++) {
                double d = (normalized - _roiPoints[i]).distance;
                if (d < minCDist) {
                  minCDist = d;
                  closestIdx = i;
                }
              }
              if (closestIdx != null) {
                setState(() => _roiPoints[closestIdx!] = normalized);
              }
            },
            child: CustomPaint(painter: AreaPainter(_roiPoints)),
          ),

          _buildUIOverlay(),
        ],
      ),
    );
  }

  Widget _buildUIOverlay() {
    return Stack(
      children: [
        Positioned(
          top: 40, left: 10, right: 10,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    IconButton(icon: const Icon(Icons.arrow_back, color: Colors.cyanAccent), onPressed: () => Navigator.pop(context)),
                    IconButton(icon: const Icon(Icons.download, color: Colors.orangeAccent), onPressed: _downloadReport),
                    IconButton(icon: const Icon(Icons.flip_camera_ios, color: Colors.cyanAccent), onPressed: _switchCamera),
                  ]),
                  _buildMetricsBox(),
                ],
              ),
              _buildCounterRow(),
            ],
          ),
        ),
        Positioned(bottom: 20, left: 20, child: Text(_statusMessage, style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 10))),
      ],
    );
  }

  Widget _buildMetricsBox() {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.black54,
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('CORE: $_processingTime', style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 8)),
        Text('FPS: $_fps', style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 8)),
      ]),
    );
  }

  Widget _buildCounterRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: _counts.entries.map((e) => _buildSmallCard(e.key.toUpperCase(), e.value)).toList()),
    );
  }

  Widget _buildSmallCard(String label, int count) {
    return Container(
      margin: const EdgeInsets.only(right: 5),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.orangeAccent)),
      child: Column(children: [
        Text(label, style: GoogleFonts.orbitron(color: Colors.white60, fontSize: 7)),
        Text("$count", style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Future<void> _sendDataToServer() async {
    try {
      await http.post(
        Uri.parse('https://tertulianoshow-counter.hf.space/analyze_counting'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'location': 'Area Mode',
          'counts': _counts,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {}
  }
}

class AreaPainter extends CustomPainter {
  final List<Offset> points;
  AreaPainter(this.points);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.cyanAccent.withOpacity(0.3)..style = PaintingStyle.fill;
    final stroke = Paint()..color = Colors.cyanAccent..style = PaintingStyle.stroke..strokeWidth = 2;
    final handle = Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill;

    final path = Path()..moveTo(points[0].dx * size.width, points[0].dy * size.height);
    for (var p in points.skip(1)) {
      path.lineTo(p.dx * size.width, p.dy * size.height);
    }
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, stroke);

    for (var p in points) {
      canvas.drawCircle(Offset(p.dx * size.width, p.dy * size.height), 8, handle);
    }
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ScanlineOverlay extends StatelessWidget {
  const ScanlineOverlay({super.key});
  @override Widget build(BuildContext context) {
    return IgnorePointer(child: ListView.builder(itemCount: 100, itemBuilder: (c, i) => Container(height: 5, color: i % 2 == 0 ? Colors.black12 : Colors.transparent)));
  }
}
