import 'package:flutter/material.dart';
import 'home_screen.dart';

void main() {
  debugPrint("Iniciando App...");
  runApp(const TerlineTCountApp());
}

class TerlineTCountApp extends StatelessWidget {
  const TerlineTCountApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TerlineT Counter',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.orange,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
