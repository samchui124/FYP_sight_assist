export 'web_camera_api_stub.dart'
    if (dart.library.js_interop) 'web_camera_api_web.dart';

import 'vision_source.dart';

typedef WebCameraFrameCallback = void Function(VisionFrame frame);
typedef WebCameraErrorCallback = void Function(String error);