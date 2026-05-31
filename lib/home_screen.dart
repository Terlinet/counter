import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:google_fonts/google_fonts.dart';
import 'counting_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;

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
          // Background Video with Cyberpunk Filter
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

          // Cyberpunk Overlay (Gradient + Scanlines)
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

          // Scanlines Effect
          const ScanlineOverlay(),

          // Content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),
                    // Glowing Title
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
                      'SYSTEM COUNTER v1.0',
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
                    const SizedBox(height: 50),

                    // Instructions
                    Text(
                      'SELECIONE O MÓDULO DE ESCANEAMENTO:',
                      style: GoogleFonts.orbitron(
                        color: Colors.white70,
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Options Grid
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Wrap(
                        spacing: 20,
                        runSpacing: 20,
                        alignment: WrapAlignment.center,
                        children: [
                          _buildCyberOption(context, 'PESSOAS', Icons.person, 'person'),
                          _buildCyberOption(context, 'CARROS', Icons.directions_car, 'car'),
                          _buildCyberOption(context, 'BIKES', Icons.directions_bike, 'bicycle'),
                          _buildCyberOption(context, 'MOTOS', Icons.motorcycle, 'motorcycle'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),

                    // Footer
                    Text(
                      'ESTADO: AGUARDANDO COMANDO...',
                      style: GoogleFonts.orbitron(
                        color: Colors.cyanAccent.withOpacity(0.5),
                        fontSize: 10,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCyberOption(BuildContext context, String label, IconData icon, String type) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const ObjectCountingScreen(),
          ),
        );
      },
      child: Container(
        width: 140,
        height: 140,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.cyanAccent.withOpacity(0.1),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Stack(
          children: [
            // Decorative accents
            Positioned(
              top: 0,
              left: 0,
              child: Container(width: 20, height: 2, color: Colors.orangeAccent),
            ),
            Positioned(
              top: 0,
              left: 0,
              child: Container(width: 2, height: 20, color: Colors.orangeAccent),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(width: 20, height: 2, color: Colors.orangeAccent),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(width: 2, height: 20, color: Colors.orangeAccent),
            ),

            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.orangeAccent, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    label,
                    style: GoogleFonts.orbitron(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
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
