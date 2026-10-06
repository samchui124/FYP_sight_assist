# pathguide

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Test on an iPhone

An iOS build requires macOS with Xcode. From the `app` directory on a Mac, run:

```sh
flutter pub get
cd ios
pod install
open Runner.xcworkspace
```

In Xcode, select the `Runner` target, choose a development team under **Signing & Capabilities**, connect the iPhone, select it as the run destination, and press **Run**. The app requests camera access on first launch. A free Personal Team can install a development build on a connected device; TestFlight distribution requires Apple Developer Program membership.
