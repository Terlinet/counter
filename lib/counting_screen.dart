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
  String _webFacingMode = 'environment';

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
      final stream = await html.window.navigator.mediaDevices?.getUserMedia({
        'video': {'facingMode': _webFacingMode},
        'audio': false
      });
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
  void _showReportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.cyanAccent, width: 2), borderRadius: BorderRadius.circular(10)),
        title: Text("SELECT REPORT TYPE", style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogOption("PIE CHART (PIZZA)", Icons.pie_chart, "pie"),
            _buildDialogOption("BAR CHART (BARRAS)", Icons.bar_chart, "bar"),
            _buildDialogOption("COLUMN CHART (COLUNAS)", Icons.insert_chart, "column"),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogOption(String label, IconData icon, String type) {
    return ListTile(
      leading: Icon(icon, color: Colors.cyanAccent),
      title: Text(label, style: GoogleFonts.orbitron(color: Colors.white, fontSize: 12)),
      onTap: () {
        Navigator.pop(context);
        _generateAdvancedReport(type);
      },
    );
  }

  void _generateAdvancedReport(String chartType) {
    final now = DateTime.now();
    final dateStr = "${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute}:${now.second}";

    // Calcula totais e dados para o gráfico
    final labels = _counts.keys.map((k) => k.toUpperCase()).toList();
    final values = _counts.values.toList();
    final total = values.fold(0, (sum, item) => sum + item);

    String chartHtml = "";

    if (chartType == "bar") {
      chartHtml = _generateBarChartHtml(labels, values);
    } else if (chartType == "column") {
      chartHtml = _generateColumnChartHtml(labels, values);
    } else {
      chartHtml = _generatePieChartHtml(labels, values, total);
    }

    final fullHtml = """
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>TERLINET AI REPORT</title>
  <style>
    body { background: #050505; color: #00ffff; font-family: 'Courier New', Courier, monospace; padding: 40px; }
    .header { border-bottom: 2px solid #ff8c00; padding-bottom: 20px; margin-bottom: 30px; }
    .title { color: #ff8c00; font-size: 28px; font-weight: bold; letter-spacing: 5px; }
    .meta { color: #00cccc; font-size: 14px; margin-top: 10px; }
    .container { display: flex; flex-direction: column; align-items: center; }
    .chart-box { width: 100%; max-width: 800px; background: rgba(0, 255, 255, 0.05); border: 1px solid #00ffff; padding: 30px; margin-top: 30px; box-shadow: 0 0 20px rgba(0, 255, 255, 0.2); }

    /* Bar Chart Styles */
    .bar-row { margin-bottom: 15px; }
    .bar-label { font-size: 14px; margin-bottom: 5px; }
    .bar-bg { background: #111; height: 25px; width: 100%; position: relative; }
    .bar-fill { background: linear-gradient(90deg, #00ffff, #ff8c00); height: 100%; transition: width 1s; }
    .bar-value { position: absolute; right: 10px; top: 3px; color: white; font-weight: bold; font-size: 14px; }

    /* Column Chart Styles */
    .col-container { display: flex; height: 300px; align-items: flex-end; justify-content: space-around; padding-top: 20px; }
    .col-item { display: flex; flex-direction: column; align-items: center; width: 60px; }
    .col-bar { background: linear-gradient(0deg, #00ffff, #ff8c00); width: 40px; transition: height 1s; }
    .col-label { font-size: 10px; margin-top: 10px; text-align: center; height: 30px; }

    /* Pie Chart Styles (Simplified with SVG) */
    .pie-svg { width: 300px; height: 300px; transform: rotate(-90deg); border-radius: 50%; }
  </style>
</head>
<body>
  <div class="header">
    <div class="title">TERLINET SYSTEM REPORT</div>
    <div class="meta">TIMESTAMP: $dateStr | LOCATION: ${kIsWeb ? "WEB_TERMINAL" : "MOBILE_UNIT_01"}</div>
  </div>

  <div class="container">
    <div class="chart-box">
      <h3 style="text-align: center; color: #ff8c00;">OBJECT DETECTION ANALYTICS</h3>
      $chartHtml
    </div>

    <div style="margin-top: 40px; width: 100%; max-width: 800px; border: 1px dashed #ff8c00; padding: 20px;">
      <h4 style="color: #ff8c00;">SUMMARY DATA:</h4>
      <ul>
        ${labels.asMap().entries.map((e) => "<li>${e.value}: ${values[e.key]} UNITS</li>").join("")}
        <li style="border-top: 1px solid #555; margin-top: 10px; padding-top: 10px; list-style: none; font-weight: bold;">TOTAL DETECTIONS: $total</li>
      </ul>
    </div>
  </div>

  <p style="text-align: center; margin-top: 50px; font-size: 10px; color: #555;">SYSTEM STATUS: SECURE | ENCRYPTION: ACTIVE | TERLINET AI CORE v1.0</p>
</body>
</html>
""";

    if (kIsWeb) {
      final bytes = utf8.encode(fullHtml);
      final blob = html.Blob([bytes], 'text/html');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..setAttribute("download", "TERLINET_REPORT_${now.millisecondsSinceEpoch}.html")
        ..click();
      html.Url.revokeObjectUrl(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("HTML REPORT GENERATED")));
    }
  }

  String _generateBarChartHtml(List<String> labels, List<int> values) {
    int maxVal = values.fold(1, (max, v) => v > max ? v : max);
    String rows = "";
    for (int i = 0; i < labels.length; i++) {
      double percent = (values[i] / maxVal) * 100;
      rows += """
      <div class="bar-row">
        <div class="bar-label">${labels[i]}</div>
        <div class="bar-bg">
          <div class="bar-fill" style="width: $percent%;"></div>
          <div class="bar-value">${values[i]}</div>
        </div>
      </div>
      """;
    }
    return rows;
  }

  String _generateColumnChartHtml(List<String> labels, List<int> values) {
    int maxVal = values.fold(1, (max, v) => v > max ? v : max);
    String cols = '<div class="col-container">';
    for (int i = 0; i < labels.length; i++) {
      double percent = (values[i] / maxVal) * 100;
      cols += """
      <div class="col-item">
        <span style="font-size: 12px; margin-bottom: 5px;">${values[i]}</span>
        <div class="col-bar" style="height: ${percent}%;"></div>
        <div class="col-label">${labels[i]}</div>
      </div>
      """;
    }
    cols += "</div>";
    return cols;
  }

  String _generatePieChartHtml(List<String> labels, List<int> values, int total) {
    if (total == 0) return "<p>NO DATA DETECTED</p>";
    String svgParts = "";
    double cumulativePercent = 0;
    final colors = ["#00ffff", "#ff8c00", "#ff00ff", "#ffff00", "#00ff00"];

    for (int i = 0; i < labels.length; i++) {
      double percent = values[i] / total;
      // Calcula o stroke-dasharray para o SVG circular
      // Perímetro do círculo r=15.9155 é 100
      double start = cumulativePercent * 100;
      double end = percent * 100;
      svgParts += '<circle cx="21" cy="21" r="15.9155" fill="transparent" stroke="${colors[i % colors.length]}" stroke-width="10" stroke-dasharray="$end 100" stroke-dashoffset="-$start"></circle>';
      cumulativePercent += percent;
    }

    String legend = '<div style="margin-top: 20px; display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">';
    for (int i = 0; i < labels.length; i++) {
      legend += '<div><span style="display:inline-block; width:12px; height:12px; background:${colors[i % colors.length]}; margin-right:5px;"></span>${labels[i]} (${((values[i]/total)*100).toStringAsFixed(1)}%)</div>';
    }
    legend += '</div>';

    return """
    <div style="display: flex; flex-direction: column; align-items: center;">
      <svg viewBox="0 0 42 42" class="pie-svg" style="width: 250px; height: 250px;">
        $svgParts
      </svg>
      $legend
    </div>
    """;
  }

  Future<void> _switchCamera() async {
    if (kIsWeb) {
      setState(() {
        _webFacingMode = (_webFacingMode == 'environment') ? 'user' : 'environment';
        _statusMessage = "SWITCHING CAMERA...";
      });
      // Para o stream atual
      final stream = _videoElement?.srcObject as html.MediaStream?;
      stream?.getTracks().forEach((track) => track.stop());
      await _startWebCamera();
    } else {
      if (_cameraController == null) return;
      final cameras = await availableCameras();
      if (cameras.length < 2) return;

      int newIndex = cameras.indexOf(_cameraController!.description) + 1;
      if (newIndex >= cameras.length) newIndex = 0;

      await _cameraController!.dispose();
      _cameraController = CameraController(
        cameras[newIndex],
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      try {
        await _cameraController!.initialize();
        if (!mounted) return;
        _cameraController!.startImageStream(_processMobileImage);
        setState(() {});
      } catch (e) {
        debugPrint("Error switching mobile camera: $e");
      }
    }
  }

  void _downloadReport() {
    final now = DateTime.now();
    final dateStr = "${now.day}/${now.month}/${now.year}";
    final timeStr = "${now.hour}:${now.minute}:${now.second}";

    final reportContent = '''
TERLINET SYSTEM COUNTER REPORT
==============================
TIMESTAMP: $dateStr $timeStr
LOCATION:  ${kIsWeb ? 'Web Console' : 'Mobile Unit'}
==============================
OBJECT COUNTS:
- PEOPLE:      ${_counts['person']}
- VEHICLES:    ${_counts['car']}
- BICYCLES:    ${_counts['bicycle']}
- MOTORCYCLES: ${_counts['motorcycle']}
==============================
SYSTEM STATUS: OPERATIONAL
END OF TRANSMISSION
''';

    if (kIsWeb) {
      final bytes = utf8.encode(reportContent);
      final blob = html.Blob([bytes], 'text/plain');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..setAttribute("download", "TERLINET_REPORT_${now.millisecondsSinceEpoch}.txt")
        ..click();
      html.Url.revokeObjectUrl(url);
    } else {
      // No mobile, apenas mostramos um snackbar por enquanto (ou poderíamos salvar em arquivo)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("REPORT GENERATED (SAVE NOT IMPLEMENTED FOR MOBILE)")),
      );
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
                  Row(
                    children: [
                      IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.cyanAccent), onPressed: () => Navigator.pop(context)),
                      IconButton(icon: const Icon(Icons.download, color: Colors.orangeAccent), onPressed: _showReportDialog),
                      IconButton(icon: const Icon(Icons.flip_camera_ios, color: Colors.cyanAccent), onPressed: _switchCamera),
                    ],
                  ),
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
          const SizedBox(width: 8),
          _buildSmallCard("MOTOS", _counts['motorcycle']!, Icons.motorcycle),
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
