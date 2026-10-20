import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/distance_estimator.dart';

void main() {
  const estimator = DistanceEstimator();

  Detection detection(int id, {double h = 0.25, double cy = 0.5}) =>
      Detection(id: id, score: 0.9, cx: 0.5, cy: cy, w: 0.2, h: h);

  test('estimates metres from focal length and typical class height', () {
    final distance = estimator.estimateMeters(
      detection: detection(6, h: 0.5),
      focalLengthVerticalPixels: 1000,
      frameHeightPixels: 1000,
    );

    expect(distance, closeTo(3.4, 1e-9));
  });

  test('returns no estimate for unsupported classes', () {
    expect(
      estimator.estimateMeters(
        detection: detection(1),
        focalLengthVerticalPixels: 1000,
        frameHeightPixels: 1000,
      ),
      isNull,
    );
  });

  test('rejects missing or invalid calibration and clipped boxes', () {
    expect(
      estimator.estimateMeters(
        detection: detection(7),
        focalLengthVerticalPixels: 0,
        frameHeightPixels: 1000,
      ),
      isNull,
    );
    expect(
      estimator.estimateMeters(
        detection: detection(7, cy: 0.1),
        focalLengthVerticalPixels: 1000,
        frameHeightPixels: 1000,
      ),
      isNull,
    );
  });
}
