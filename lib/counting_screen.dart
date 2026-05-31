import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

class ObjectCountingScreen extends StatefulWidget {
  const ObjectCountingScreen({super.key});

  @override
  State<ObjectCountingScreen> createState() => _ObjectCountingScreenState();
}

class _ObjectCountingScreenState extends State<ObjectCountingScreen> {
  CameraController? _cameraController;
  ObjectDetector? _objectDetector;
  bool _isDetecting = false;
  List<DetectedObject> _detectedObjects = [];

  String _processingTime = '0ms';
  String _fps = '0';
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  Timer? _reportTimer;

  final Map<String, int> _counts = {
    'Person': 0,
    'Car': 0,
    'Bicycle': 0,
    'Motorcycle': 0,
  };

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _initializeObjectDetector();

    // Timer para reportar ao servidor a cada 10 segundos
    _reportTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _sendDataToServer();
    });
  }

  void _initializeObjectDetector() {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    );
    _objectDetector = ObjectDetector(options: options);
  }

  Future<void> _initializeCamera() async {
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

      _cameraController!.startImageStream(_processCameraImage);
      setState(() {});
    } catch (e) {
      debugPrint('Erro ao inicializar câmera: $e');
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isDetecting || _objectDetector == null) return;
    _isDetecting = true;

    final startTime = DateTime.now();

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final objects = await _objectDetector!.processImage(inputImage);

      if (mounted) {
        setState(() {
          _detectedObjects = objects;
          _processingTime = '${DateTime.now().difference(startTime).inMilliseconds}ms';
          _updateFPS();

          // Atualiza contadores locais baseados no que está visível agora
          for (var obj in objects) {
            if (obj.labels.isNotEmpty) {
              String label = obj.labels.first.text;
              if (_counts.containsKey(label)) {
                _counts[label] = (_counts[label] ?? 0) + 1;
              }
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Erro no processamento: $e');
    } finally {
      _isDetecting = false;
    }
  }

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
    if (_detectedObjects.isEmpty) return;

    Map<String, int> currentFrameCounts = {};
    for (var obj in _detectedObjects) {
      if (obj.labels.isNotEmpty) {
        String label = obj.labels.first.text;
        currentFrameCounts[label] = (currentFrameCounts[label] ?? 0) + 1;
      }
    }

    try {
      // Usando o endpoint do servidor configurado anteriormente
      await http.post(
        Uri.parse('https://tertulianoshow-counter.hf.space/analyze_counting'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'location': 'Mobile Scanner',
          'counts': currentFrameCounts,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      debugPrint('Erro ao reportar ao servidor: $e');
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final sensorOrientation = _cameraController!.description.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationValue = sensorOrientation;
      rotation = InputImageRotationValue.fromRawValue(rotationValue);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _cameraController?.dispose();
    _objectDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Feed da Câmera
          Center(
            child: CameraPreview(_cameraController!),
          ),

          // Efeito visual de Scanline
          const ScanlineOverlay(),

          // Pintor das Caixas (Overlay)
          CustomPaint(
            painter: ObjectDetectorPainter(
              _detectedObjects,
              _cameraController!.value.previewSize!,
              _cameraController!.description.sensorOrientation,
            ),
          ),

          // HUD de Performance e Contagem
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 10,
            right: 10,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, color: Colors.cyanAccent),
                      onPressed: () => Navigator.pop(context),
                    ),
                    _buildMetricsOverlay(),
                  ],
                ),
                const SizedBox(height: 10),
                _buildCountCards(),
              ],
            ),
          ),

          // Borda do HUD
          _buildHUDFrame(),
        ],
      ),
    );
  }

  Widget _buildMetricsOverlay() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black54,
        border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('LATÊNCIA: $_processingTime', style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 10)),
          Text('FPS: $_fps', style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildCountCards() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildCountCard("PESSOAS", _counts['Person']!, Icons.person),
          const SizedBox(width: 10),
          _buildCountCard("CARROS", _counts['Car']!, Icons.directions_car),
          const SizedBox(width: 10),
          _buildCountCard("BIKES", _counts['Bicycle']!, Icons.directions_bike),
        ],
      ),
    );
  }

  Widget _buildCountCard(String label, int count, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        border: Border.all(color: Colors.orangeAccent.withOpacity(0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.cyanAccent, size: 16),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: GoogleFonts.orbitron(color: Colors.white70, fontSize: 8)),
              Text("$count", style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 14, fontWeight: FontWeight.bold)),
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
}

class ObjectDetectorPainter extends CustomPainter {
  ObjectDetectorPainter(this.objects, this.imageSize, this.rotation);

  final List<DetectedObject> objects;
  final Size imageSize;
  final int rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.cyanAccent;

    for (final DetectedObject object in objects) {
      final double scaleX = size.width / (Platform.isAndroid ? imageSize.height : imageSize.width);
      final double scaleY = size.height / (Platform.isAndroid ? imageSize.width : imageSize.height);

      final rect = Rect.fromLTRB(
        object.boundingBox.left * scaleX,
        object.boundingBox.top * scaleY,
        object.boundingBox.right * scaleX,
        object.boundingBox.bottom * scaleY,
      );

      canvas.drawRect(rect, paint);

      if (object.labels.isNotEmpty) {
        final label = object.labels.first;
        final textPainter = TextPainter(
          text: TextSpan(
            text: '${label.text.toUpperCase()} (${(label.confidence * 100).toStringAsFixed(0)}%)',
            style: GoogleFonts.orbitron(color: Colors.black, backgroundColor: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        textPainter.paint(canvas, Offset(rect.left, rect.top - 15));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ScanlineOverlay extends StatelessWidget {
  const ScanlineOverlay({super.key});
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 100,
        itemBuilder: (context, index) {
          return Container(
            height: 4,
            width: double.infinity,
            color: index % 2 == 0 ? Colors.black.withOpacity(0.1) : Colors.transparent,
          );
        },
      ),
    );
  }
}
