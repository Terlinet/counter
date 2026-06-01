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
  void _showReportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.cyanAccent, width: 2), borderRadius: BorderRadius.circular(10)),
        title: Text("SELECT AREA REPORT", style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogOption("PIE CHART", Icons.pie_chart, "pie"),
            _buildDialogOption("BAR CHART", Icons.bar_chart, "bar"),
            _buildDialogOption("COLUMN CHART", Icons.insert_chart, "column"),
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
    final labels = _counts.keys.map((k) => k.toUpperCase()).toList();
    final values = _counts.values.toList();
    final total = values.fold(0, (sum, item) => sum + item);

    String chartHtml = "";
    if (chartType == "bar") chartHtml = _generateBarChartHtml(labels, values);
    else if (chartType == "column") chartHtml = _generateColumnChartHtml(labels, values);
    else chartHtml = _generatePieChartHtml(labels, values, total);

    final fullHtml = """
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>TERLINET AREA REPORT</title>
  <style>
    body { background: #050505; color: #00ffff; font-family: 'Courier New', Courier, monospace; padding: 40px; }
    .header { border-bottom: 2px solid #ff8c00; padding-bottom: 20px; margin-bottom: 30px; }
    .title { color: #ff8c00; font-size: 28px; font-weight: bold; letter-spacing: 5px; }
    .meta { color: #00cccc; font-size: 14px; margin-top: 10px; }
    .container { display: flex; flex-direction: column; align-items: center; }
    .chart-box { width: 100%; max-width: 800px; background: rgba(0, 255, 255, 0.05); border: 1px solid #00ffff; padding: 30px; margin-top: 30px; box-shadow: 0 0 20px rgba(0, 255, 255, 0.2); }
    .bar-row { margin-bottom: 15px; } .bar-label { font-size: 14px; margin-bottom: 5px; }
    .bar-bg { background: #111; height: 25px; width: 100%; position: relative; }
    .bar-fill { background: linear-gradient(90deg, #00ffff, #ff8c00); height: 100%; }
    .bar-value { position: absolute; right: 10px; top: 3px; color: white; font-weight: bold; }
    .col-container { display: flex; height: 300px; align-items: flex-end; justify-content: space-around; padding-top: 20px; }
    .col-item { display: flex; flex-direction: column; align-items: center; width: 60px; }
    .col-bar { background: linear-gradient(0deg, #00ffff, #ff8c00); width: 40px; }
    .pie-svg { width: 300px; height: 300px; transform: rotate(-90deg); border-radius: 50%; }
  </style>
</head>
<body>
  <div class="header">
    <div class="title">TERLINET AREA REPORT</div>
    <div class="meta">TIMESTAMP: $dateStr | MODE: AREA_DETECTION_CORE</div>
  </div>
  <div class="container">
    <div class="chart-box"><h3 style="text-align:center; color:#ff8c00;">AREA ANALYTICS</h3>$chartHtml</div>
    <div style="margin-top:40px; width:100%; max-width:800px; border:1px dashed #ff8c00; padding:20px;">
      <h4 style="color:#ff8c00;">SUMMARY DATA:</h4>
      <ul>${labels.asMap().entries.map((e) => "<li>${e.value}: ${values[e.key]}</li>").join("")}</ul>
    </div>
  </div>
</body>
</html>
""";

    if (kIsWeb) {
      final blob = html.Blob([utf8.encode(fullHtml)], 'text/html');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)..setAttribute("download", "AREA_REPORT_${now.millisecondsSinceEpoch}.html")..click();
      html.Url.revokeObjectUrl(url);
    }
  }

  String _generateBarChartHtml(List<String> labels, List<int> values) {
    int maxVal = values.fold(1, (max, v) => v > max ? v : max);
    String rows = "";
    for (int i = 0; i < labels.length; i++) {
      double percent = (values[i] / maxVal) * 100;
      rows += '<div class="bar-row"><div class="bar-label">${labels[i]}</div><div class="bar-bg"><div class="bar-fill" style="width: $percent%;"></div><div class="bar-value">${values[i]}</div></div></div>';
    }
    return rows;
  }

  String _generateColumnChartHtml(List<String> labels, List<int> values) {
    int maxVal = values.fold(1, (max, v) => v > max ? v : max);
    String cols = '<div class="col-container">';
    for (int i = 0; i < labels.length; i++) {
      double percent = (values[i] / maxVal) * 100;
      cols += '<div class="col-item"><span style="font-size:12px;">${values[i]}</span><div class="col-bar" style="height:${percent}%;"></div><div style="font-size:10px;">${labels[i]}</div></div>';
    }
    return cols + "</div>";
  }

  String _generatePieChartHtml(List<String> labels, List<int> values, int total) {
    if (total == 0) return "<p>NO DATA</p>";
    String svgParts = "";
    double cumulativePercent = 0;
    final colors = ["#00ffff", "#ff8c00", "#ff00ff", "#ffff00", "#00ff00", "#ff0000", "#0000ff"];
    for (int i = 0; i < labels.length; i++) {
      double percent = values[i] / total;
      double start = cumulativePercent * 100;
      double end = percent * 100;
      svgParts += '<circle cx="21" cy="21" r="15.9155" fill="transparent" stroke="${colors[i % colors.length]}" stroke-width="10" stroke-dasharray="$end 100" stroke-dashoffset="-$start"></circle>';
      cumulativePercent += percent;
    }
    return '<div style="display:flex; flex-direction:column; align-items:center;"><svg viewBox="0 0 42 42" class="pie-svg">$svgParts</svg></div>';
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
                    IconButton(icon: const Icon(Icons.download, color: Colors.orangeAccent), onPressed: _showReportDialog),
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
