import 'dart:async';
import 'dart:ui' show Size;

import 'vision_source.dart';
import 'web_camera_api.dart';

class WebVisionSource implements VisionSource {
  final StreamController<VisionFrame> _controller =
      StreamController<VisionFrame>.broadcast();

  double _threshold = 0.30;
  int _frameWidth = 1280;
  int _frameHeight = 720;

  @override
  String get displayName => '浏览器相机';

  @override
  Size get frameSize => Size(_frameWidth.toDouble(), _frameHeight.toDouble());

  @override
  int get rotationDegrees => 0;

  @override
  Stream<VisionFrame> get frames => _controller.stream;

  @override
  double get threshold => _threshold;

  @override
  set threshold(double value) {
    _threshold = value.clamp(0.0, 1.0);
    updateWebCameraThreshold(_threshold);
  }

  @override
  Future<VisionSourceStatus> initialize() async {
    final error = await startWebCamera(
      threshold: _threshold,
      onFrame: (frame) {
        _frameWidth = frame.frameWidth;
        _frameHeight = frame.frameHeight;
        if (!_controller.isClosed) _controller.add(frame);
      },
      onError: (message) {
        if (!_controller.isClosed) _controller.addError(StateError(message));
      },
    );
    if (error != null) {
      return VisionSourceStatus(
        ok: false,
        message: '浏览器相机未启动',
        error: error,
      );
    }
    return const VisionSourceStatus(
      ok: true,
      message: '实时相机识别已启动（TFLite）',
    );
  }

  @override
  Future<VisionDiagnostics?> diagnostics() async => null;

  @override
  Future<void> dispose() async {
    await stopWebCamera();
    await _controller.close();
  }
}