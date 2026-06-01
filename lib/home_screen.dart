import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'counting_screen.dart';
import 'area_counting_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  String _aiMessage = "CONNECTING TO IA CORE...";

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset('assets/videos/video.mp4')
      ..initialize().then((_) {
        setState(() {
          _isInitialized = true;
        });
        _controller.setLooping(true);
        _controller.setVolume(0);
        _controller.play();
      }).catchError((error) {
        debugPrint("Erro ao carregar vídeo: $error");
      });

    _fetchAIIntro();
  }

  Future<void> _fetchAIIntro() async {
    try {
      // Link do seu servidor no Hugging Face
      final response = await http.get(Uri.parse('https://tertulianoshow-counter.hf.space/explain_system'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _aiMessage = data['message'].toUpperCase();
        });
      }
    } catch (e) {
      setState(() {
        _aiMessage = "TERLINET EYES: SISTEMA OPERACIONAL. AGUARDANDO COMANDO DE ESCANEAMENTO.";
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isInitialized)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                ),
              ),
            ),

          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.8),
                  Colors.blue.withOpacity(0.1),
                  Colors.black.withOpacity(0.9),
                ],
              ),
            ),
          ),

          const ScanlineOverlay(),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),
                    Text(
                      'TERLINET',
                      style: GoogleFonts.orbitron(
                        color: Colors.cyanAccent,
                        fontSize: MediaQuery.of(context).size.width * 0.08 + 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 10,
                        shadows: [
                          const Shadow(color: Colors.cyan, blurRadius: 20),
                          const Shadow(color: Colors.cyanAccent, blurRadius: 40),
                        ],
                      ),
                    ),
                    Text(
                      'SYSTEM IA COUNTER',
                      style: GoogleFonts.orbitron(
                        color: Colors.orangeAccent,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        shadows: [
                          const Shadow(color: Colors.orange, blurRadius: 10),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),

                    // AI Transmission Box
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 30),
                      child: Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 1),
                          boxShadow: [
                            BoxShadow(color: Colors.cyanAccent.withOpacity(0.1), blurRadius: 10)
                          ]
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.record_voice_over, color: Colors.orangeAccent, size: 16),
                                const SizedBox(width: 8),
                                Text(
                                  "TERLINET EYES TRANSMISSION:",
                                  style: GoogleFonts.orbitron(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _aiMessage,
                              style: GoogleFonts.orbitron(color: Colors.white, fontSize: 11, letterSpacing: 1),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 40),

                    Text(
                      'SELECIONE O MÓDULO DE ESCANEAMENTO:',
                      style: GoogleFonts.orbitron(color: Colors.white70, fontSize: 10, letterSpacing: 1),
                    ),
                    const SizedBox(height: 20),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Wrap(
                        spacing: 20,
                        runSpacing: 20,
                        alignment: WrapAlignment.center,
                        children: [
                          _buildCyberOption(context, 'PESSOAS', Icons.person, const ObjectCountingScreen()),
                          _buildCyberOption(context, 'CARROS', Icons.directions_car, const ObjectCountingScreen()),
                          _buildCyberOption(context, 'ÁREA IA', Icons.ads_click, const AreaCountingScreen()),
                          _buildCyberOption(context, 'BIKES', Icons.directions_bike, const ObjectCountingScreen()),
                          _buildCyberOption(context, 'MOTOS', Icons.motorcycle, const ObjectCountingScreen()),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),

                    Text(
                      'STATUS: AI CORE ONLINE',
                      style: GoogleFonts.orbitron(color: Colors.cyanAccent.withOpacity(0.5), fontSize: 9, letterSpacing: 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCyberOption(BuildContext context, String label, IconData icon, Widget screen) {
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (context) => screen));
      },
      child: Container(
        width: 130,
        height: 130,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 1),
        ),
        child: Stack(
          children: [
            Positioned(top: 0, left: 0, child: Container(width: 15, height: 2, color: Colors.orangeAccent)),
            Positioned(top: 0, left: 0, child: Container(width: 2, height: 15, color: Colors.orangeAccent)),
            Positioned(bottom: 0, right: 0, child: Container(width: 15, height: 2, color: Colors.orangeAccent)),
            Positioned(bottom: 0, right: 0, child: Container(width: 2, height: 15, color: Colors.orangeAccent)),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.orangeAccent, size: 35),
                  const SizedBox(height: 12),
                  Text(
                    label,
                    style: GoogleFonts.orbitron(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
        ),
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
        itemCount: 100,
        itemBuilder: (context, index) {
          return Container(
            height: 4,
            width: double.infinity,
            color: index % 2 == 0 ? Colors.black.withOpacity(0.15) : Colors.transparent,
          );
        },
      ),
    );
  }
}
