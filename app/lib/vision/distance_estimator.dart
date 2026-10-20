import 'detection.dart';
import 'labels.dart';

/// Camera-calibrated monocular range estimates for classes with a typical size.
///
/// These are approximate because individual objects vary in size and detector
/// boxes are imperfect. No estimate is returned for unsupported or clipped
/// detections.
class DistanceEstimator {
  const DistanceEstimator();

  static const Map<String, double> _typicalHeightsMeters = <String, double>{
    'pedestrian': 1.70,
    'bin': 0.75,
    'bicycle': 1.00,
  };

  double? estimateMeters({
    required Detection detection,
    required double focalLengthVerticalPixels,
    required double frameHeightPixels,
  }) {
    if (!focalLengthVerticalPixels.isFinite ||
        focalLengthVerticalPixels <= 0 ||
        !frameHeightPixels.isFinite ||
        frameHeightPixels <= 0 ||
        detection.h <= 0) {
      return null;
    }

    final label = labelOf(detection.id);
    final typicalHeight = label == null
        ? null
        : _typicalHeightsMeters[label.nameEn];
    if (typicalHeight == null) return null;

    final rect = detection.normalizedRect;
    if (rect.top <= 0.01 || rect.bottom >= 0.99) return null;

    final boxHeightPixels = detection.h * frameHeightPixels;
    if (boxHeightPixels <= 0) return null;
    final distanceMeters =
        focalLengthVerticalPixels * typicalHeight / boxHeightPixels;

    if (!distanceMeters.isFinite ||
        distanceMeters < 0.5 ||
        distanceMeters > 10) {
      return null;
    }
    return distanceMeters;
  }
}
