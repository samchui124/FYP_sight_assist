import 'dart:async';
import 'dart:io';

import 'capture_result.dart';
import 'frame_upload_sink.dart';

typedef CaptureFrameFn = Future<CaptureResult> Function();

/// Periodically asks native code to JPEG-save the latest camera frame.
///
/// Owns the timer only — encoding and disk I/O stay on the native side.
class FrameSampler {
  FrameSampler({
    required this.capture,
    this.interval = const Duration(seconds: 5),
    this.maxFiles = 200,
    FrameUploadSink? uploadSink,
    this.onResult,
  }) : uploadSink = uploadSink ?? const NoopUploadSink();

  final CaptureFrameFn capture;
  final Duration interval;
  final int maxFiles;
  final FrameUploadSink uploadSink;
  final void Function(CaptureResult result)? onResult;

  Timer? _timer;
  int _savedCount = 0;
  bool _tickInFlight = false;

  int get savedCount => _savedCount;

  bool get isRunning => _timer != null;

  /// Start periodic capture. Fires once immediately, then every [interval].
  void start() {
    stop();
    _timer = Timer.periodic(interval, (_) {
      unawaited(_tick());
    });
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _tickInFlight = false;
  }

  Future<void> _tick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      final result = await capture();
      if (result.ok && result.path != null) {
        _savedCount += 1;
        final file = File(result.path!);
        await _prune(file.parent);
        await uploadSink.enqueue(file);
      }
      onResult?.call(result);
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _prune(Directory dir) async {
    if (maxFiles <= 0 || !dir.existsSync()) return;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    while (files.length > maxFiles) {
      final oldest = files.removeAt(0);
      try {
        await oldest.delete();
      } on FileSystemException {
        // Best-effort; next tick can retry.
      }
    }
  }
}
