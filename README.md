# TerlineT Counter - CyberPunk Version 🛣️

Sistema de contagem de objetos (Pessoas, Carros, Bicicletas e Motos) utilizando visão computacional (TensorFlow.js) diretamente no navegador.

## 🚀 Funcionalidades
- **Detecção em Tempo Real**: Identificação automática de objetos via câmera.
- **Estilo CyberPunk**: Interface imersiva com neon, scanlines e elementos futuristas.
- **Localização Inteligente**: Detecção automática de coordenadas via GPS ou entrada manual.
- **Relatórios**: Geração de relatórios (.txt) com data, hora, local e contagem para download/impressão.
- **Web App**: Funciona em qualquer dispositivo com navegador e câmera.

## 🛠️ Tecnologias
- Flutter Web
- TensorFlow.js (COCO-SSD)
- Google Fonts (Orbitron)
- Geolocator API

## 📦 Como executar
1. Certifique-se de ter o Flutter instalado.
2. Clone o repositório.
3. Coloque um vídeo de fundo em `assets/videos/video.mp4`.
4. Execute:
   ```bash
   flutter pub get
   flutter run -d chrome --web-renderer html
   ```

## 📄 Licença
Desenvolvido para TerlineT.
