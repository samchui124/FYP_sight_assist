/// Result of asking the native side to save the latest camera frame as JPEG.
class CaptureResult {
  const CaptureResult({
    required this.ok,
    this.path,
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
    this.error,
  });

  final bool ok;
  final String? path;
  final int width;
  final int height;

  /// On-disk JPEG size in bytes (not pixel buffer size).
  final int bytes;
  final String? error;

  factory CaptureResult.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) {
      return const CaptureResult(ok: false, error: 'empty reply');
    }
    int asInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    }

    return CaptureResult(
      ok: raw['ok'] == true,
      path: raw['path'] as String?,
      width: asInt(raw['width']),
      height: asInt(raw['height']),
      bytes: asInt(raw['bytes']),
      error: raw['error'] as String?,
    );
  }

  static CaptureResult fail(String message) =>
      CaptureResult(ok: false, error: message);
}
