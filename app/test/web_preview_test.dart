import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/main_web_preview.dart';

void main() {
  testWidgets('web preview navigates to guidance and back', (tester) async {
    AppLocale.current = AppLanguage.en;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const PathGuideWebPreviewApp());

    expect(find.text('Start guidance'), findsOneWidget);
    expect(
      find.textContaining('Web preview only: camera, object detection'),
      findsOneWidget,
    );

    await tester.tap(find.text('Start guidance'));
    await tester.pumpAndSettle();
    expect(find.text('Start guidance'), findsOneWidget);
    expect(find.text('Camera not started'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Read text'), findsOneWidget);

    await tester.tap(find.text('Read text'));
    await tester.pumpAndSettle();
    expect(find.text('Text mode. Point at text and it will be read out.'), findsOneWidget);
    expect(find.text('Read again'), findsOneWidget);
  });
}
