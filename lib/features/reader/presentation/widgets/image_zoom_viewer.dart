import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A35 画廊/正文图全屏查看器：捏合缩放 + 拖拽平移
class ImageZoomViewer extends StatefulWidget {
  final Uint8List bytes;
  final String? heroTag;

  const ImageZoomViewer({super.key, required this.bytes, this.heroTag});

  static Future<void> open(BuildContext context, Uint8List bytes, {String? heroTag}) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => ImageZoomViewer(bytes: bytes, heroTag: heroTag),
    );
  }

  @override
  State<ImageZoomViewer> createState() => _ImageZoomViewerState();
}

class _ImageZoomViewerState extends State<ImageZoomViewer> {
  ui.Image? _decoded;
  final TransformationController _tc = TransformationController();

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.bytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _decoded = frame.image);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _decoded;
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (img == null)
              const Center(child: CircularProgressIndicator())
            else
              InteractiveViewer(
                transformationController: _tc,
                minScale: 0.5,
                maxScale: 5.0,
                child: Center(
                  child: RawImage(
                    image: img,
                    fit: BoxFit.contain,
                    width: MediaQuery.of(context).size.width,
                    height: MediaQuery.of(context).size.height,
                  ),
                ),
              ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
