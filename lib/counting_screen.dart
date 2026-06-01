import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart' as mlkit;
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

// Imports para Web (usando universal_html para compilar em mobile)
import 'package:universal_html/html.dart' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

class ObjectCountingScreen extends StatefulWidget {
  const ObjectCountingScreen({super.key});

  @override
  State<ObjectCountingScreen> createState() => _ObjectCountingScreenState();
}

class _ObjectCountingScreenState extends State<ObjectCountingScreen> {
  // --- Mobile State ---
  CameraController? _cameraController;
  mlkit.ObjectDetector? _objectDetector;
  bool _isDetecting = false;
  List<mlkit.DetectedObject> _detectedObjects = [];

  // --- Web State ---
  html.VideoElement? _videoElement;
  bool _modelReady = false;
  List<WebDetection> _webDetections = [];
  Timer? _detectionTimer;
  dynamic _readyListener;
  dynamic _errorListener;

  // --- Common State ---
  String _statusMessage = "INITIALIZING...";
  String _processingTime = '0ms';
  String _fps = '0';
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  Timer? _reportTimer;

  final Map<String, int> _counts = {
    'person': 0,
    'car': 0,
    'bicycle': 0,
    'motorcycle': 0,
  };

  @override
  void initState() {
    super.initState();

    if (kIsWeb) {
      _initWeb();
    } else {
      _initMobile();
    }

    _reportTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _sendDataToServer();
    });
  }

  // ========================== WEB LOGIC ==========================
  void _initWeb() {
    ui_web.platformViewRegistry.registerViewFactory('video-view', (int viewId) {
      final container = html.DivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = 'black';

      _videoElement = html.VideoElement()
        ..id = 'counting-video'
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover';

      container.append(_videoElement!);
      return container;
    });

    _startWebCamera();
    _loadWebModel();
  }

  Future<void> _startWebCamera() async {
    try {
      final stream = await html.window.navigator.mediaDevices?.getUserMedia({'video': true, 'audio': false});
      if (_videoElement != null && stream != null) {
        _videoElement!.srcObject = stream;
      } else {
        setState(() => _statusMessage = "CÂMERA INDISPONÍVEL");
      }
    } catch (e) {
      setState(() => _statusMessage = "PERMISSÃO NEGADA: $e");
    }
  }

  Future<void> _loadWebModel() async {
    _readyListener = (_) {
      if (mounted) {
        setState(() {
          _modelReady = true;
          _statusMessage = "WEB SCANNER ACTIVE";
        });
        _startWebLoop();
      }
    };
    _errorListener = (_) {
      if (mounted) {
        setState(() => _statusMessage = "IA CORE ERROR");
      }
    };

    html.window.addEventListener('mediapipe-ready', _readyListener);
    html.window.addEventListener('mediapipe-error', _errorListener);

    if (html.document.querySelector('#counting-video') != null) {
      js.context.callMethod('initObjectDetectorV3');
    } else {
      // Se ainda não existir, tenta em um pequeno delay
      Future.delayed(const Duration(milliseconds: 500), () {
        js.context.callMethod('initObjectDetectorV3');
      });
    }
  }

  void _startWebLoop() {
    _detectionTimer?.cancel();
    _detectionTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || !_modelReady) {
        timer.cancel();
        return;
      }
      _runWebDetection();
    });
  }

  void _runWebDetection() {
    try {
      final result = js.context.callMethod('runObjectDetection', ['counting-video']);
      if (result != null) {
        final List<dynamic> predictions = result as List<dynamic>;
        final List<WebDetection> detections = [];

        // Para evitar contagem infinita, limpamos as contagens atuais do frame
        final Map<String, int> frameCounts = {};

        for (var p in predictions) {
          final List<dynamic> bbox = p['bbox'] as List<dynamic>;
          final String label = p['class'].toString().toLowerCase();
          final double score = (p['score'] as num).toDouble();

          detections.add(WebDetection(
            label: label,
            score: score,
            rect: Rect.fromLTWH(
              (bbox[0] as num).toDouble(),
              (bbox[1] as num).toDouble(),
              (bbox[2] as num).toDouble(),
              (bbox[3] as num).toDouble(),
            ),
          ));

          if (score > 0.5) {
            frameCounts[label] = (frameCounts[label] ?? 0) + 1;
          }
        }

        if (mounted) {
          setState(() {
            _webDetections = detections;
            _updateFPS();
            // Atualiza _counts apenas com os objetos do frame atual
            _counts.updateAll((key, value) => frameCounts[key] ?? 0);
          });
        }
      }
    } catch (e) {
      debugPrint("Erro loop web: $e");
    }
  }

  // ========================== MOBILE LOGIC ==========================
  Future<void> _initMobile() async {
    final options = mlkit.ObjectDetectorOptions(
      mode: mlkit.DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    );
    _objectDetector = mlkit.ObjectDetector(options: options);

    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    _cameraController = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      _cameraController!.startImageStream(_processMobileImage);
      setState(() => _statusMessage = "MOBILE SCANNER ACTIVE");
    } catch (e) {
      setState(() => _statusMessage = "CAM ERROR: $e");
    }
  }

  Future<void> _processMobileImage(CameraImage image) async {
    if (_isDetecting || _objectDetector == null) return;
    _isDetecting = true;
    final startTime = DateTime.now();
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage != null) {
        final objects = await _objectDetector!.processImage(inputImage);
        if (mounted) {
          setState(() {
            _detectedObjects = objects;
            _processingTime = '${DateTime.now().difference(startTime).inMilliseconds}ms';
            _updateFPS();
            for (var obj in objects) {
              if (obj.labels.isNotEmpty) {
                String label = obj.labels.first.text.toLowerCase();
                if (_counts.containsKey(label)) {
                  _counts[label] = _counts[label]! + 1;
                }
              }
            }
          });
        }
      }
    } finally {
      _isDetecting = false;
    }
  }

  mlkit.InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (kIsWeb) return null;
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

  // ========================== COMMON LOGIC ==========================
  void _updateFPS() {
    _frameCount++;
    final now = DateTime.now();
    if (_lastFpsUpdate == null || now.difference(_lastFpsUpdate!).inSeconds >= 1) {
      _fps = _frameCount.toString();
      _frameCount = 0;
      _lastFpsUpdate = now;
    }
  }

  Future<void> _sendDataToServer() async {
    Map<String, int> currentCounts = {};
    if (kIsWeb) {
      for (var d in _webDetections) {
        currentCounts[d.label] = (currentCounts[d.label] ?? 0) + 1;
      }
    } else {
      for (var obj in _detectedObjects) {
        if (obj.labels.isNotEmpty) {
          String label = obj.labels.first.text.toLowerCase();
          currentCounts[label] = (currentCounts[label] ?? 0) + 1;
        }
      }
    }
    if (currentCounts.isEmpty) return;
    try {
      await http.post(
        Uri.parse('https://tertulianoshow-counter.hf.space/analyze_counting'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'location': kIsWeb ? 'Web Console' : 'Mobile Unit',
          'counts': currentCounts,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {}
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _detectionTimer?.cancel();
    _cameraController?.dispose();
    _objectDetector?.close();
    if (kIsWeb) {
      html.window.removeEventListener('mediapipe-ready', _readyListener);
      html.window.removeEventListener('mediapipe-error', _errorListener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Feed
          if (kIsWeb)
            const HtmlElementView(viewType: 'video-view')
          else if (_cameraController != null && _cameraController!.value.isInitialized)
            CameraPreview(_cameraController!),

          const ScanlineOverlay(),

          // Painters
          if (kIsWeb)
            CustomPaint(painter: WebDetectionPainter(_webDetections))
          else if (_cameraController != null && _cameraController!.value.isInitialized)
            CustomPaint(
              painter: MobileDetectionPainter(
                _detectedObjects,
                _cameraController!.value.previewSize!,
                _cameraController!.description.sensorOrientation,
              ),
            ),

          _buildUIOverlay(),
        ],
      ),
    );
  }

  Widget _buildUIOverlay() {
    return Stack(
      children: [
        _buildHUDFrame(),
        Positioned(
          top: MediaQuery.of(context).padding.top + 10,
          left: 10,
          right: 10,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.cyanAccent), onPressed: () => Navigator.pop(context)),
                  _buildMetricsBox(),
                ],
              ),
              const SizedBox(height: 10),
              _buildCounterRow(),
            ],
          ),
        ),
        Positioned(
          bottom: 20,
          left: 20,
          child: Text(_statusMessage.toUpperCase(), style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _buildMetricsBox() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('CORE: $_processingTime', style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 9)),
          Text('FPS: $_fps', style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 9)),
        ],
      ),
    );
  }

  Widget _buildCounterRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildSmallCard("PEOPLE", _counts['person']!, Icons.person),
          const SizedBox(width: 8),
          _buildSmallCard("VEHICLES", _counts['car']!, Icons.directions_car),
          const SizedBox(width: 8),
          _buildSmallCard("BIKES", _counts['bicycle']!, Icons.directions_bike),
        ],
      ),
    );
  }

  Widget _buildSmallCard(String label, int count, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), border: Border.all(color: Colors.orangeAccent.withOpacity(0.5))),
      child: Row(
        children: [
          Icon(icon, color: Colors.cyanAccent, size: 14),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: GoogleFonts.orbitron(color: Colors.white60, fontSize: 7)),
              Text("$count", style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHUDFrame() {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(top: 10, left: 10, child: _corner(0)),
          Positioned(top: 10, right: 10, child: _corner(1)),
          Positioned(bottom: 10, left: 10, child: _corner(2)),
          Positioned(bottom: 10, right: 10, child: _corner(3)),
        ],
      ),
    );
  }

  Widget _corner(int i) => Container(width: 30, height: 30, decoration: BoxDecoration(border: Border(top: i < 2 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none, bottom: i >= 2 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none, left: i % 2 == 0 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none, right: i % 2 != 0 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none)));
}

class WebDetection {
  final String label;
  final double score;
  final Rect rect;
  WebDetection({required this.label, required this.score, required this.rect});
}

class WebDetectionPainter extends CustomPainter {
  final List<WebDetection> detections;
  WebDetectionPainter(this.detections);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.stroke..strokeWidth = 2;
    for (var d in detections) {
      canvas.drawRect(d.rect, paint);
    }
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class MobileDetectionPainter extends CustomPainter {
  final List<mlkit.DetectedObject> objects;
  final Size imageSize;
  final int rotation;
  MobileDetectionPainter(this.objects, this.imageSize, this.rotation);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.stroke..strokeWidth = 2;
    for (var obj in objects) {
      final double scaleX = size.width / imageSize.height;
      final double scaleY = size.height / imageSize.width;
      canvas.drawRect(Rect.fromLTRB(obj.boundingBox.left * scaleX, obj.boundingBox.top * scaleY, obj.boundingBox.right * scaleX, obj.boundingBox.bottom * scaleY), paint);
    }
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ScanlineOverlay extends StatelessWidget {
  const ScanlineOverlay({super.key});
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(child: ListView.builder(physics: const NeverScrollableScrollPhysics(), itemCount: 100, itemBuilder: (c, i) => Container(height: 4, color: i % 2 == 0 ? Colors.black.withOpacity(0.05) : Colors.transparent)));
  }
}
