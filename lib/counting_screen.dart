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
  html.DivElement? _videoContainer;
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
  Key _cameraViewKey = UniqueKey();

  double _videoWidth = 640;
  double _videoHeight = 480;

  @override
  void initState() {
    super.initState();
    // Registrar a visualização uma única vez com fábrica dinâmica
    ui_web.platformViewRegistry.registerViewFactory(
      'video-view',
      (int viewId) {
        _videoContainer = html.DivElement()
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.backgroundColor = 'black';
        return _videoContainer!;
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
      _videoElement = html.VideoElement()
        ..id = 'counting-video'
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.backgroundColor = 'black'
        ..style.transform = _facingMode == 'user' ? 'scaleX(-1)' : 'none';

      _videoElement!.srcObject = stream;

      // Aguarda o vídeo estar realmente pronto para tocar com buffer estável
      await _videoElement!.onCanPlayThrough.first;
      _videoElement!.play();

      debugPrint("✅ Camera hardware linked and playing");

      // Verificação se o elemento de vídeo está no DOM (para debug)
      Future.delayed(const Duration(seconds: 1), () {
        debugPrint('Video element exists in DOM? ${html.document.getElementById('counting-video') != null}');
      });

      // Aguarda o container estar na tela e anexa o vídeo
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_videoContainer != null && _videoElement != null) {
          _videoContainer!.children.clear();
          _videoContainer!.append(_videoElement!);
        }
      });

      if (mounted) {
        setState(() {
          _cameraViewKey = UniqueKey();
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
    _videoContainer?.children.clear();
    _videoContainer = null;
  }

  // --- MODELO (MediaPipe Object Detector) ---
  Future<void> _loadModel() async {
    try {
      if (!mounted) return;
      setState(() {
        _modelReady = false;
        _statusMessage = "WAKING UP NEURAL CORE...";
      });

      Completer<void> modelCompleter = Completer();

      // Injeta o código de inicialização do MediaPipe com versão sincronizada
      js.context.callMethod('eval', [
        '''
        (async () => {
          try {
            let retry = 0;
            while (typeof FilesetResolver === 'undefined' && retry < 50) {
              await new Promise(r => setTimeout(r, 200));
              retry++;
            }
            if (typeof FilesetResolver === 'undefined') {
              throw new Error("FilesetResolver not found");
            }

            // Usa a mesma versão (0.10.17) para o WASM
            const vision = await FilesetResolver.forVisionTasks(
              "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.17/wasm"
            );

            // Configuração do detector
            const options = {
              baseOptions: {
                modelAssetPath: "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float16/1/efficientdet_lite0.tflite",
                delegate: "GPU" // Tentativa inicial com GPU
              },
              runningMode: "VIDEO",
              scoreThreshold: 0.3
            };

            try {
              window.objectDetector = await ObjectDetector.createFromOptions(vision, options);
              console.log("🎯 MediaPipe initialized: GPU");
            } catch (gpuError) {
              console.warn("⚠️ GPU fail, trying CPU...", gpuError);
              options.baseOptions.delegate = "CPU";
              window.objectDetector = await ObjectDetector.createFromOptions(vision, options);
              console.log("🎯 MediaPipe initialized: CPU");
            }

            window.runDetection = async function() {
              if (!window.objectDetector) return [];
              const video = document.getElementById('counting-video');
              if (!video || video.readyState < 2) return [];

              try {
                const result = window.objectDetector.detectForVideo(video, performance.now());
                const allowed = ['person', 'car', 'bicycle', 'motorcycle'];
                return result.detections
                  .filter(d => d.categories[0].score > 0.3 && allowed.includes(d.categories[0].categoryName))
                  .map(d => ({
                    class: d.categories[0].categoryName,
                    score: d.categories[0].score,
                    bbox: [
                      d.boundingBox.originX,
                      d.boundingBox.originY,
                      d.boundingBox.width,
                      d.boundingBox.height
                    ]
                  }));
              } catch (err) {
                return [];
              }
            };

            window.dispatchEvent(new Event('mediapipe-ready'));
          } catch (e) {
            console.error("FATAL IA BOOT ERROR:", e);
            window.dispatchEvent(new Event('mediapipe-error'));
          }
        })()
        '''
      ]);

      html.window.addEventListener('mediapipe-ready', (_) {
        if (!modelCompleter.isCompleted) modelCompleter.complete();
      });
      html.window.addEventListener('mediapipe-error', (_) {
        if (!modelCompleter.isCompleted) modelCompleter.completeError("FAIL");
      });

      // Aguarda até 45s (suficiente para o download do modelo de 4MB)
      await modelCompleter.future.timeout(const Duration(seconds: 45));

      if (mounted) {
        setState(() {
          _modelReady = true;
          _statusMessage = "SCANNING ACTIVE";
        });
        _startDetectionLoop();
      }
    } catch (e) {
      debugPrint("Erro final: $e");
      if (mounted) {
        setState(() {
          _statusMessage = "IA ERROR - TAP TO RETRY";
          _modelReady = false;
        });
      }
    }
  }

  Future<void> _loadScript(String url) async {
    // Scripts agora são carregados via index.html para maior estabilidade
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
      if (video == null || video.readyState < 2) {
        _isDetecting = false;
        return;
      }

      // Atualiza dimensões reais da câmera
      if (video.videoWidth > 0) {
        _videoWidth = video.videoWidth.toDouble();
        _videoHeight = video.videoHeight.toDouble();
      }

      // Chama a função global registrada no carregamento do modelo
      final jsPromise = js_util.callMethod(js.context, 'runDetection', []);
      final result = await js_util.promiseToFuture(jsPromise);

      if (result == null) {
         _isDetecting = false;
         return;
      }

      final List<dynamic> predictions = result as List<dynamic>;
      debugPrint("Detecções recebidas: ${predictions.length}");
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
            Positioned.fill(
              child: HtmlElementView(
                key: _cameraViewKey,
                viewType: 'video-view',
              ),
            ),

          // Scanlines
          const ScanlineOverlay(),

          // Overlay com bounding boxes
          if (_detections.isNotEmpty && _modelReady)
            Positioned.fill(
              child: CustomPaint(
                painter: DetectionPainter(
                  _detections,
                  MediaQuery.of(context).size,
                  _videoWidth,
                  _videoHeight,
                  isMirrored: _facingMode == 'user',
                ),
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
                    onTap: () {
                      if (_statusMessage.contains("RETRY")) {
                        _loadModel();
                      } else {
                        _showManualLocationDialog();
                      }
                    },
                    child: Row(
                      children: [
                        if (_statusMessage.contains("RETRY"))
                          const Icon(Icons.refresh, color: Colors.orangeAccent, size: 14)
                        else
                          const Icon(Icons.location_on, color: Colors.orangeAccent, size: 14),
                        const SizedBox(width: 5),
                        Text(
                          _statusMessage.contains("RETRY") ? "RETRY IA BOOT" : "LOC: $_currentLocation",
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
  final double videoWidth;
  final double videoHeight;
  final bool isMirrored;

  DetectionPainter(this.detections, this.screenSize, this.videoWidth, this.videoHeight, {this.isMirrored = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (videoWidth == 0 || videoHeight == 0) return;

    // Lógica para BoxFit.cover (preenche a tela cortando bordas se necessário)
    double scale;
    double offsetX = 0;
    double offsetY = 0;

    double screenAspect = screenSize.width / screenSize.height;
    double videoAspect = videoWidth / videoHeight;

    if (screenAspect > videoAspect) {
      scale = screenSize.width / videoWidth;
      offsetY = (screenSize.height - videoHeight * scale) / 2;
    } else {
      scale = screenSize.height / videoHeight;
      offsetX = (screenSize.width - videoWidth * scale) / 2;
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

      double left = src.left * scale + offsetX;
      double top = src.top * scale + offsetY;
      double width = src.width * scale;
      double height = src.height * scale;

      // Se estiver espelhado (câmera frontal), inverte a coordenada X do desenho
      if (isMirrored) {
        left = screenSize.width - left - width;
      }

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
