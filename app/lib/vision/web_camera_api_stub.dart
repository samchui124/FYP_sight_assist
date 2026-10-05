import 'package:flutter/widgets.dart';

import 'vision_source.dart';

void registerWebCameraView() {}

Widget buildWebCameraView() =>
    const ColoredBox(color: Color(0xFF101418));

Future<String?> startWebCamera({
  required double threshold,
  required void Function(VisionFrame frame) onFrame,
  required void Function(String error) onError,
}) async =>
    '浏览器相机仅支持 Web';

void updateWebCameraThreshold(double threshold) {}

Future<void> stopWebCamera() async {}