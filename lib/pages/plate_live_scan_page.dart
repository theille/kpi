import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class PlateLiveScanPage extends StatefulWidget {
  const PlateLiveScanPage({super.key});

  @override
  State<PlateLiveScanPage> createState() => _PlateLiveScanPageState();
}

class _PlateLiveScanPageState extends State<PlateLiveScanPage> {
  CameraController? _controller;
  bool _initializing = true;

  final TextRecognizer _recognizer =
  TextRecognizer(script: TextRecognitionScript.latin);

  bool _busy = false;
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);

  String? _lastPlateDisplay; // ce qu'on affiche (avec tirets/espaces)
  String? _lastPlateNorm;    // version normalisée pour stabilité
  int _stableCount = 0;

  // Réglages
  static const Duration throttle = Duration(milliseconds: 450);
  static const int stableNeeded = 2; // même plaque détectée 2 fois -> OK

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
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
      await _controller!.startImageStream(_onFrame);
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

  // --------- Utils Plaques ---------

  String _normPlate(String p) =>
      p.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  String _formatSivFromNorm(String norm) {
    // AB123CD -> AB-123-CD
    if (RegExp(r'^[A-Z]{2}[0-9]{3}[A-Z]{2}$').hasMatch(norm)) {
      return "${norm.substring(0, 2)}-${norm.substring(2, 5)}-${norm.substring(5, 7)}";
    }
    // ancien : on renvoie tel quel si déjà formaté par regex
    return norm;
  }

  String? _extractPlateFromLine(String text) {
    final upper = text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9\s-]'), ' ');

    // SIV : AB-123-CD ou AB123CD
    final siv = RegExp(r'\b([A-Z]{2})\s*-?\s*([0-9]{3})\s*-?\s*([A-Z]{2})\b');
    final m1 = siv.firstMatch(upper);
    if (m1 != null) {
      return "${m1.group(1)}-${m1.group(2)}-${m1.group(3)}";
    }

    // Ancien (approx) : 123 ABC 45 / 123ABC45
    final old =
    RegExp(r'\b([0-9]{1,4})\s*-?\s*([A-Z]{1,3})\s*-?\s*([0-9]{2})\b');
    final m2 = old.firstMatch(upper);
    if (m2 != null) {
      return "${m2.group(1)} ${m2.group(2)} ${m2.group(3)}";
    }

    return null;
  }

  String? _extractPlateFromRecognized(RecognizedText rt) {
    // On scanne ligne par ligne pour éviter que le texte autour "pollue"
    for (final block in rt.blocks) {
      for (final line in block.lines) {
        final p = _extractPlateFromLine(line.text);
        if (p != null) return p;
      }
    }
    return null;
  }

  // --------- CameraImage -> InputImage ---------

  InputImage? _toInputImage(CameraImage image, CameraDescription camera) {
    try {
      final rotation = _rotationIntToImageRotation(camera.sensorOrientation);
      final size = Size(image.width.toDouble(), image.height.toDouble());
      final plane = image.planes.first;

      if (Platform.isAndroid) {
        return InputImage.fromBytes(
          bytes: plane.bytes,
          metadata: InputImageMetadata(
            size: size,
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: plane.bytesPerRow,
          ),
        );
      }

      if (Platform.isIOS) {
        return InputImage.fromBytes(
          bytes: plane.bytes,
          metadata: InputImageMetadata(
            size: size,
            rotation: rotation,
            format: InputImageFormat.bgra8888,
            bytesPerRow: plane.bytesPerRow,
          ),
        );
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  InputImageRotation _rotationIntToImageRotation(int rotation) {
    switch (rotation) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      case 0:
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  // --------- Live Frame ---------

  Future<void> _onFrame(CameraImage image) async {
    if (_controller == null) return;
    if (_busy) return;

    final now = DateTime.now();
    if (now.difference(_lastRun) < throttle) return;
    _lastRun = now;

    _busy = true;

    try {
      final input = _toInputImage(image, _controller!.description);
      if (input == null) {
        _busy = false;
        return;
      }

      final recognized = await _recognizer.processImage(input);
      final plate = _extractPlateFromRecognized(recognized);

      if (!mounted) return;

      if (plate == null) {
        // rien trouvé -> reset
        _stableCount = 0;
        _lastPlateDisplay = null;
        _lastPlateNorm = null;
        setState(() {});
        return;
      }

      final norm = _normPlate(plate);

      // stabilité sur la version normalisée
      if (_lastPlateNorm == norm) {
        _stableCount++;
      } else {
        _lastPlateNorm = norm;
        _lastPlateDisplay = plate;
        _stableCount = 1;
      }

      setState(() {});

      if (_stableCount >= stableNeeded) {
        await _stopStreamSafely();
        if (!mounted) return;

        final formatted = _formatSivFromNorm(norm);
        Navigator.pop(context, formatted);
      }
    } catch (_) {
      // en live, on évite d'afficher des erreurs
    } finally {
      _busy = false;
    }
  }

  Future<void> _stopStreamSafely() async {
    try {
      if (_controller != null && _controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopStreamSafely();
    _recognizer.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Scan plaque (LIVE)")),
      body: Stack(
        children: [
          if (_controller != null) CameraPreview(_controller!),

          // Cadre de visée
          Center(
            child: Container(
              width: 340,
              height: 130,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),

          // Indication + plaque détectée
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _lastPlateDisplay == null
                    ? "Vise la plaque dans le cadre…"
                    : "Détecté : $_lastPlateDisplay  (${_stableCount}/${stableNeeded})",
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
