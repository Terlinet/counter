// counting_screen.dart
// Requer execução em Flutter web (usa dart:html e TensorFlow.js via CDN)
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
  CameraStatus _cameraStatus = CameraStatus.loading;

  bool _modelReady = false;
  String _statusMessage = "INITIALIZING CORE...";
  String _currentLocation = "DETECTING...";
  String _facingMode = 'environment'; // 'user' or 'environment'
  List<Detection> _detections = [];
  final Map<String, int> _counts = {
    'person': 0,
    'car': 0,
    'bicycle': 0,
    'motorcycle': 0,
  };

  int? _animationFrameId;
  bool _isDetecting = false;

  static const int _detectionIntervalMs = 200;
  DateTime _lastDetectionTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Registrar a visualização uma única vez com fábrica dinâmica
    ui_web.platformViewRegistry.registerViewFactory(
      'video-view',
      (int viewId) {
        final container = html.DivElement()
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.backgroundColor = 'black';
        if (_videoElement != null) {
          container.append(_videoElement!);
        }
        return container;
      },
    );
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

  // ---------------------- LOCALIZAÇÃO ----------------------
  Future<void> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    try {
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _currentLocation = "DISABLED");
        return;
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() => _currentLocation = "DENIED");
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() => _currentLocation = "PERM. DENIED");
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 5),
      );
      setState(() {
        _currentLocation = "${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}";
      });
    } catch (e) {
      setState(() => _currentLocation = "NOT DETECTED");
    }
  }

  void _showManualLocationDialog() {
    final TextEditingController locationController = TextEditingController(text: _currentLocation == "DETECTING..." ? "" : _currentLocation);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        shape: Border.all(color: Colors.cyanAccent, width: 2),
        title: Text("MANUAL OVERRIDE: LOCATION", style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 14)),
        content: TextField(
          controller: locationController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: "ENTER LOCATION",
            labelStyle: TextStyle(color: Colors.cyanAccent),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCEL", style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _currentLocation = locationController.text.toUpperCase());
              Navigator.pop(context);
            },
            child: const Text("CONFIRM", style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  // ---------------------- RELATÓRIO ----------------------
  void _downloadReport() {
    final now = DateTime.now();
    final dateStr = DateFormat('dd/MM/yyyy').format(now);
    final timeStr = DateFormat('HH:mm:ss').format(now);

    final reportContent = '''
TERLINET SYSTEM COUNTER REPORT
==============================
TIMESTAMP: $dateStr $timeStr
LOCATION:  $_currentLocation
==============================
OBJECT COUNTS:
- PEOPLE:      ${_counts['person']}
- VEHICLES:    ${_counts['car']}
- BICYCLES:    ${_counts['bicycle']}
- MOTORCYCLES: ${_counts['motorcycle']}
==============================
SYSTEM STATUS: SECURE
END OF TRANSMISSION
''';

    final bytes = reportContent.codeUnits;
    final blob = html.Blob([bytes], 'text/plain');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute("download", "TERLINET_REPORT_${now.millisecondsSinceEpoch}.txt")
      ..click();
    html.Url.revokeObjectUrl(url);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: Colors.cyanAccent,
        content: Text("REPORT DOWNLOADED TO LOCAL STORAGE", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
      ),
    );
  }

  // ---------------------- CÂMERA ----------------------
  Future<void> _switchCamera() async {
    _stopCamera();
    setState(() {
      _facingMode = (_facingMode == 'environment') ? 'user' : 'environment';
      _cameraStatus = CameraStatus.loading;
      _statusMessage = "SWITCHING CAMERA...";
    });
    await _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        setState(() => _cameraStatus = CameraStatus.error);
        return;
      }

      // Limpar stream anterior
      _mediaStream?.getTracks().forEach((track) => track.stop());

      final stream = await mediaDevices.getUserMedia({
        'video': {
          'facingMode': _facingMode,
          'width': {'ideal': 640},
          'height': {'ideal': 480}
        },
        'audio': false
      });
      _mediaStream = stream;

      // Criar o elemento de vídeo se não existir
      _videoElement ??= html.VideoElement()
        ..id = 'counting-video'
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.backgroundColor = 'black';

      _videoElement!.srcObject = stream;

      // Aguarda o vídeo estar realmente pronto para tocar
      await _videoElement!.onCanPlay.first;
      _videoElement!.play();

      if (mounted) {
        setState(() {
          _cameraStatus = CameraStatus.available;
          _statusMessage = "LOADING NEURAL NETWORK...";
        });
      }
    } catch (e) {
      debugPrint("Erro ao iniciar câmera: $e");
      if (mounted) {
        setState(() {
          _cameraStatus = CameraStatus.error;
          _statusMessage = "CÂMERA NÃO ENCONTRADA OU ACESSO NEGADO.";
        });
      }
    }
  }

  void _stopCamera() {
    _mediaStream?.getTracks().forEach((track) => track.stop());
    _videoElement?.remove();
    _videoElement = null;
  }

  // ---------------------- MODELO (TF.JS + COCO-SSD) ----------------------
  Future<void> _loadModel() async {
    await _loadScript('https://cdn.jsdelivr.net/npm/@tensorflow/tfjs');
    await _loadScript('https://cdn.jsdelivr.net/npm/@tensorflow-models/coco-ssd');

    Completer<void> modelCompleter = Completer();
    js.context.callMethod('eval', [
      '''
      window.cocoModel = null;
      cocoSsd.load().then(model => {
        window.cocoModel = model;
        window.dispatchEvent(new Event('coco-model-ready'));
      });
      '''
    ]);
    html.window.addEventListener('coco-model-ready', (_) {
      if (!modelCompleter.isCompleted) modelCompleter.complete();
    });
    await modelCompleter.future;

    if (mounted) {
      setState(() {
        _modelReady = true;
        _statusMessage = "SCANNING ACTIVE";
      });
      _startDetectionLoop();
    }
  }

  Future<void> _loadScript(String url) {
    Completer<void> completer = Completer();
    final script = html.ScriptElement()
      ..src = url
      ..async = true
      ..onLoad.listen((_) => completer.complete())
      ..onError.listen((e) => completer.completeError(e));
    html.document.head!.append(script);
    return completer.future;
  }

  // ---------------------- LOOP DE DETECÇÃO ----------------------
  void _startDetectionLoop() {
    if (_animationFrameId != null) return;
    void detectFrame(num _) {
      _runDetection();
      _animationFrameId = html.window.requestAnimationFrame(detectFrame);
    }
    _animationFrameId = html.window.requestAnimationFrame(detectFrame);
  }

  void _stopDetectionLoop() {
    if (_animationFrameId != null) {
      html.window.cancelAnimationFrame(_animationFrameId!);
      _animationFrameId = null;
    }
  }

  Future<void> _runDetection() async {
    if (!_modelReady || _isDetecting) return;
    final now = DateTime.now();
    if (now.difference(_lastDetectionTime).inMilliseconds < _detectionIntervalMs) {
      return;
    }
    _isDetecting = true;
    _lastDetectionTime = now;

    try {
      final video = _videoElement;
      if (video == null || video.readyState != 4) {
        _isDetecting = false;
        return;
      }

      // Chama o modelo JS via js_util para tratar a Promise corretamente
      final jsPromise = js_util.callMethod(
        js.context,
        'eval',
        [
          '''
          (async () => {
            if (!window.cocoModel) return [];
            const video = document.getElementById('counting-video');
            if (!video || video.readyState < 2) return [];
            const predictions = await window.cocoModel.detect(video);
            return predictions;
          })()
          '''
        ],
      );

      final result = await js_util.promiseToFuture(jsPromise);

      if (result == null) {
         _isDetecting = false;
         return;
      }

      final List<dynamic> predictions = result as List<dynamic>;
      final List<Detection> detections = [];
      final Map<String, int> newCounts = {'person': 0, 'car': 0, 'bicycle': 0, 'motorcycle': 0};

      for (var pred in predictions) {
        final String classLabel = pred['class'];
        if (newCounts.containsKey(classLabel)) {
          newCounts[classLabel] = newCounts[classLabel]! + 1;
          final bbox = pred['bbox'] as List<dynamic>;
          detections.add(Detection(
            label: classLabel,
            confidence: (pred['score'] as num).toDouble(),
            rect: Rect.fromLTWH(
              (bbox[0] as num).toDouble(),
              (bbox[1] as num).toDouble(),
              (bbox[2] as num).toDouble(),
              (bbox[3] as num).toDouble(),
            ),
          ));
        }
      }

      if (mounted) {
        setState(() {
          _detections = detections;
          _counts.addAll(newCounts);
        });
      }
    } catch (e) {
      // ignore
    } finally {
      _isDetecting = false;
    }
  }

  // ---------------------- UI ----------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Feed da câmera (background)
          if (_cameraStatus == CameraStatus.available)
            const Positioned.fill(
              child: HtmlElementView(
                viewType: 'video-view',
              ),
            ),

          // Scanlines
          const ScanlineOverlay(),

          // Overlay com bounding boxes
          if (_detections.isNotEmpty && _modelReady)
            Positioned.fill(
              child: CustomPaint(
                painter: DetectionPainter(_detections, MediaQuery.of(context).size),
                size: MediaQuery.of(context).size,
              ),
            ),

          // Cyber HUD Decoration (Corners)
          _buildHUDFrame(),

          // Status Bar (Bottom)
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                border: Border.all(color: Colors.cyanAccent, width: 1),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _modelReady ? Colors.greenAccent : Colors.redAccent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _modelReady ? Colors.greenAccent : Colors.redAccent,
                          blurRadius: 5,
                        )
                      ],
                    ),
                  ),
                  const SizedBox(width: 15),
                  Text(
                    _statusMessage,
                    style: GoogleFonts.orbitron(
                      color: Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _showManualLocationDialog,
                    child: Row(
                      children: [
                        const Icon(Icons.location_on, color: Colors.orangeAccent, size: 14),
                        const SizedBox(width: 5),
                        Text(
                          "LOC: $_currentLocation",
                          style: GoogleFonts.orbitron(color: Colors.white70, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Mensagem de erro / loading
          if (_cameraStatus != CameraStatus.available || !_modelReady)
            Container(
              color: Colors.black.withOpacity(0.8),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_modelReady) const CircularProgressIndicator(color: Colors.orangeAccent),
                    const SizedBox(height: 30),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 30),
                      child: Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.orbitron(color: Colors.white, fontSize: 14),
                      ),
                    ),
                    if (_cameraStatus == CameraStatus.error)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Column(
                          children: [
                            ElevatedButton(
                              onPressed: () => html.window.location.reload(),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
                              child: const Text("REBOOT SYSTEM"),
                            ),
                            const SizedBox(height: 10),
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                "VOLTAR PARA HOME",
                                style: GoogleFonts.orbitron(
                                  color: Colors.cyanAccent,
                                  fontSize: 12,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // Cards de contagem (topo)
          Positioned(
            top: MediaQuery.of(context).padding.top + 20,
            left: 20,
            right: 20,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildCountCard("PESSOAS", _counts['person']!, Icons.person),
                        const SizedBox(width: 10),
                        _buildCountCard("CARROS", _counts['car']!, Icons.directions_car),
                        const SizedBox(width: 10),
                        _buildCountCard("BIKES", _counts['bicycle']!, Icons.directions_bike),
                        const SizedBox(width: 10),
                        _buildCountCard("MOTOS", _counts['motorcycle']!, Icons.motorcycle),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Botão Switch Camera
                _buildActionButton(Icons.flip_camera_ios, _switchCamera, Colors.orangeAccent),
                const SizedBox(width: 10),
                // Botão Download Report
                _buildActionButton(Icons.download, _downloadReport, Colors.cyanAccent),
              ],
            ),
          ),

          // Botão voltar
          Positioned(
            top: MediaQuery.of(context).padding.top + 20,
            left: 10,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.cyanAccent),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHUDFrame() {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(top: 10, left: 10, child: _hudCorner(0)),
          Positioned(top: 10, right: 10, child: _hudCorner(1)),
          Positioned(bottom: 10, left: 10, child: _hudCorner(2)),
          Positioned(bottom: 10, right: 10, child: _hudCorner(3)),
        ],
      ),
    );
  }

  Widget _hudCorner(int index) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        border: Border(
          top: index < 2 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none,
          bottom: index >= 2 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none,
          left: index % 2 == 0 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none,
          right: index % 2 != 0 ? const BorderSide(color: Colors.cyanAccent, width: 2) : BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildCountCard(String label, int count, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        border: Border.all(color: Colors.orangeAccent.withOpacity(0.8), width: 1),
        boxShadow: [
          BoxShadow(color: Colors.orangeAccent.withOpacity(0.2), blurRadius: 8),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.cyanAccent, size: 16),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: GoogleFonts.orbitron(
                      color: Colors.white70, fontSize: 8, fontWeight: FontWeight.bold)),
              Text("$count",
                  style: GoogleFonts.orbitron(
                      color: Colors.orangeAccent, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(IconData icon, VoidCallback onTap, Color color) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          border: Border.all(color: color, width: 2),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}

class ScanlineOverlay extends StatelessWidget {
  const ScanlineOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 200,
        itemBuilder: (context, index) {
          return Container(
            height: 2,
            width: double.infinity,
            color: index % 2 == 0 ? Colors.white.withOpacity(0.03) : Colors.transparent,
          );
        },
      ),
    );
  }
}

class Detection {
  final String label;
  final double confidence;
  final Rect rect;

  Detection({required this.label, required this.confidence, required this.rect});
}

class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  final Size screenSize;

  DetectionPainter(this.detections, this.screenSize);

  @override
  void paint(Canvas canvas, Size size) {
    final double videoWidth = 640;
    final double videoHeight = 480;

    final double videoAspect = videoWidth / videoHeight;
    final double screenAspect = screenSize.width / screenSize.height;
    double scaleW, scaleH, offsetX, offsetY;

    if (screenAspect < videoAspect) {
      scaleH = screenSize.height;
      scaleW = scaleH * videoAspect;
      offsetX = (screenSize.width - scaleW) / 2;
      offsetY = 0;
    } else {
      scaleW = screenSize.width;
      scaleH = scaleW / videoAspect;
      offsetX = 0;
      offsetY = (screenSize.height - scaleH) / 2;
    }

    final paintRect = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final paintCorner = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    final textStyle = GoogleFonts.orbitron(
      color: Colors.black,
      fontSize: 10,
      fontWeight: FontWeight.bold,
      backgroundColor: Colors.cyanAccent,
    );

    for (var det in detections) {
      final Rect src = det.rect;

      double left = src.left * (scaleW / videoWidth) + offsetX;
      double top = src.top * (scaleH / videoHeight) + offsetY;
      double width = src.width * (scaleW / videoWidth);
      double height = src.height * (scaleH / videoHeight);

      final rect = Rect.fromLTWH(left, top, width, height);

      canvas.drawRect(rect, paintRect);

      double cs = 15;
      canvas.drawLine(Offset(left, top), Offset(left + cs, top), paintCorner);
      canvas.drawLine(Offset(left, top), Offset(left, top + cs), paintCorner);

      canvas.drawLine(Offset(left + width, top), Offset(left + width - cs, top), paintCorner);
      canvas.drawLine(Offset(left + width, top), Offset(left + width, top + cs), paintCorner);

      canvas.drawLine(Offset(left, top + height), Offset(left + cs, top + height), paintCorner);
      canvas.drawLine(Offset(left, top + height), Offset(left, top + height - cs), paintCorner);

      canvas.drawLine(Offset(left + width, top + height), Offset(left + width - cs, top + height), paintCorner);
      canvas.drawLine(Offset(left + width, top + height), Offset(left + width, top + height - cs), paintCorner);

      final textSpan = TextSpan(
        text: " ${det.label.toUpperCase()} ${(det.confidence * 100).toInt()}% ",
        style: textStyle,
      );
      final textPainter = TextPainter(text: textSpan, textDirection: ui.TextDirection.ltr);
      textPainter.layout();
      textPainter.paint(canvas, Offset(left, top - 18));
    }
  }

  @override
  bool shouldRepaint(DetectionPainter oldDelegate) => true;
}
