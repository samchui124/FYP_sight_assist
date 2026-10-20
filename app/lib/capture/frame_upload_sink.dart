import 'dart:io';

/// Future upload hook for captured sample frames.
///
/// v1 does not talk to a server — use [NoopUploadSink].
abstract class FrameUploadSink {
  Future<void> enqueue(File file);
}

/// Drop-in that ignores files (local-only capture phase).
class NoopUploadSink implements FrameUploadSink {
  const NoopUploadSink();

  @override
  Future<void> enqueue(File file) async {}
}
