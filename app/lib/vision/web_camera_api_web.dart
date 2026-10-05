import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'detection.dart';
import 'vision_source.dart';

const String _viewType = 'pathguide/web-camera-preview';

@JS('isSecureContext')
external JSBoolean get _isSecureContext;

@JS('pathGuideStartCamera')
external JSPromise<JSString?> _pathGuideStartCamera(
  web.HTMLVideoElement video,
  double threshold,
);

@JS('pathGuideSetThreshold')
external void _pathGuideSetThreshold(double threshold);

@JS('pathGuideStopCamera')
external void _pathGuideStopCamera();

web.HTMLVideoElement? _video;
JSFunction? _frameListener;
JSFunction? _errorListener;
void Function(VisionFrame)? _onFrame;
void Function(String)? _onError;

void registerWebCameraView() {
  if (_video != null) return;
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
    _video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', '')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = '#101418';
    return _video!;
  });
}

Widget buildWebCameraView() => const HtmlElementView(viewType: _viewType);

Future<String?> startWebCamera({
  required double threshold,
  required void Function(VisionFrame frame) onFrame,
  required void Function(String error) onError,
}) async {
  final video = _video;
  if (video == null) return '相机预览尚未准备好，请重试';
  if (!_isSecureContext.toDart) {
    return '浏览器相机需要 HTTPS；请通过安全连接打开此页面';
  }

  _removeListeners();
  _onFrame = onFrame;
  _onError = onError;
  _frameListener = _handleFrame.toJS;
  _errorListener = _handleError.toJS;
  web.window.addEventListener('pathguide-web-frame', _frameListener);
  web.window.addEventListener('pathguide-web-error', _errorListener);

  try {
    final error = await _pathGuideStartCamera(video, threshold).toDart;
    return error?.toDart;
  } catch (error) {
    _removeListeners();
    return '启动浏览器相机失败：$error';
  }
}

void updateWebCameraThreshold(double threshold) =>
    _pathGuideSetThreshold(threshold);

Future<void> stopWebCamera() async {
  _removeListeners();
  _pathGuideStopCamera();
}

void _removeListeners() {
  final frameListener = _frameListener;
  if (frameListener != null) {
    web.window.removeEventListener('pathguide-web-frame', frameListener);
  }
  final errorListener = _errorListener;
  if (errorListener != null) {
    web.window.removeEventListener('pathguide-web-error', errorListener);
  }
  _frameListener = null;
  _errorListener = null;
  _onFrame = null;
  _onError = null;
}

void _handleFrame(web.Event event) {
  final detail = (event as web.CustomEvent).detail;
  if (detail == null) return;
  final data = jsonDecode((detail as JSString).toDart);
  if (data is! Map) return;
  final detections = <Detection>[];
  final rawDetections = data['detections'];
  if (rawDetections is List) {
    for (final raw in rawDetections) {
      final detection = Detection.fromMap(raw);
      if (detection != null) detections.add(detection);
    }
  }
  _onFrame?.call(VisionFrame(
    detections: detections,
    inferenceMs: _asDouble(data['inferenceMs']),
    frameWidth: _asInt(data['frameWidth']),
    frameHeight: _asInt(data['frameHeight']),
  ));
}

void _handleError(web.Event event) {
  final detail = (event as web.CustomEvent).detail;
  if (detail == null) return;
  final data = jsonDecode((detail as JSString).toDart);
  if (data is Map) _onError?.call(data['error']?.toString() ?? '相机推理失败');
}

int _asInt(Object? value) => value is num ? value.round() : 0;

double _asDouble(Object? value) => value is num ? value.toDouble() : 0;