import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class PlateScanPage extends StatefulWidget {
  final Future<void> Function(String plate) onPlateConfirmed;

  const PlateScanPage({
    super.key,
    required this.onPlateConfirmed,
  });

  @override
  State<PlateScanPage> createState() => _PlateScanPageState();
}

class _PlateScanPageState extends State<PlateScanPage> {
  CameraController? _controller;
  bool _initializing = true;
  bool _processing = false;

  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  String? _lastDetectedPlate; // affichage en bas

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup:
        Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur caméra : $e")),
      );
      Navigator.pop(context);
      return;
    }

    if (!mounted) return;
    setState(() => _initializing = false);
  }

  String? _extractPlate(String text) {
    final upper = text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9\s-]'), ' ');

    final siv = RegExp(r'\b([A-Z]{2})\s*-?\s*([0-9]{3})\s*-?\s*([A-Z]{2})\b');
    final m1 = siv.firstMatch(upper);
    if (m1 != null) {
      return "${m1.group(1)}-${m1.group(2)}-${m1.group(3)}";
    }

    final old =
    RegExp(r'\b([0-9]{1,4})\s*-?\s*([A-Z]{1,3})\s*-?\s*([0-9]{2})\b');
    final m2 = old.firstMatch(upper);
    if (m2 != null) {
      return "${m2.group(1)} ${m2.group(2)} ${m2.group(3)}";
    }

    return null;
  }

  Future<bool> _confirmDialog(String plate) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Confirmer la plaque"),
        content: Text("Plaque détectée :\n\n$plate"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Reprendre"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Valider"),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _takeAndRecognize() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_processing) return;

    setState(() => _processing = true);

    try {
      // Important : sur certains devices, il faut stopper le preview un instant
      // mais en général takePicture marche sans stop.
      final file = await _controller!.takePicture();

      final inputImage = InputImage.fromFilePath(file.path);
      final recognized = await _textRecognizer.processImage(inputImage);

      final plate = _extractPlate(recognized.text);

      if (!mounted) return;

      if (plate == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Aucune plaque détectée. Rapproche-toi et évite le flou/reflets.")),
        );
        setState(() => _processing = false);
        return;
      }

      setState(() => _lastDetectedPlate = plate);

      // Popup confirmation (simple)
      final ok = await _confirmDialog(plate);
      if (!ok) {
        setState(() => _processing = false);
        return;
      }

      // Ici on déclenche la validation côté page KPI (qui gère aussi l’approximation)
      await widget.onPlateConfirmed(plate);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Validation envoyée ✅")),
      );

      // prêt pour un autre scan
      setState(() => _processing = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur OCR : $e")),
      );
      setState(() => _processing = false);
    }
  }

  @override
  void dispose() {
    _textRecognizer.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Scanner une plaque"),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_controller != null) CameraPreview(_controller!),

          Center(
            child: Container(
              width: 320,
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          Positioned(
            left: 16,
            right: 16,
            bottom: 90,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _lastDetectedPlate == null
                    ? "Cadre la plaque puis prends la photo"
                    : "Dernière détection : $_lastDetectedPlate",
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),

          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: ElevatedButton.icon(
              onPressed: _processing ? null : _takeAndRecognize,
              icon: const Icon(Icons.camera_alt),
              label: Text(_processing ? "Analyse..." : "Prendre la photo"),
            ),
          ),
        ],
      ),
    );
  }
}
