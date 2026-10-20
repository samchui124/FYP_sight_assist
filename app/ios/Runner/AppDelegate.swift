import Flutter
import CoreLocation
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let locationManager = CLLocationManager()
  private var pendingLocationPermissionResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let mapsApiKey = findMapsApiKey() {
      GMSServices.provideAPIKey(mapsApiKey)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    VisionPlugin.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "VisionPlugin"))
    let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "NavigationPermissionPlugin"
    )
    let channel = FlutterMethodChannel(
      name: "hk.pathguide/navigation_permissions",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "requestLocation" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.requestLocationPermission(result)
    }
    locationManager.delegate = self
  }

  private func findMapsApiKey() -> String? {
    if let environmentKey = ProcessInfo.processInfo.environment["MAPS_API_KEY"],
       !environmentKey.isEmpty
    {
      return environmentKey
    }
    guard let encodedDefines = Bundle.main.infoDictionary?["DART_DEFINES"] as? String else {
      return nil
    }
    for encodedDefine in encodedDefines.split(separator: ",") {
      guard
        let data = Data(base64Encoded: String(encodedDefine)),
        let define = String(data: data, encoding: .utf8)
      else {
        continue
      }
      let separator = define.firstIndex(of: "=")
      guard let separator, String(define[..<separator]) == "MAPS_API_KEY" else {
        continue
      }
      let key = String(define[define.index(after: separator)...])
      return key.isEmpty ? nil : key
    }
    return nil
  }

  private func requestLocationPermission(_ result: @escaping FlutterResult) {
    switch locationManager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      result(true)
    case .notDetermined:
      guard pendingLocationPermissionResult == nil else {
        result(FlutterError(
          code: "permission_in_progress",
          message: "A location request is already active.",
          details: nil
        ))
        return
      }
      pendingLocationPermissionResult = result
      locationManager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      result(false)
    @unknown default:
      result(false)
    }
  }
}

extension AppDelegate: CLLocationManagerDelegate {
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard let result = pendingLocationPermissionResult else { return }
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      pendingLocationPermissionResult = nil
      result(true)
    case .denied, .restricted:
      pendingLocationPermissionResult = nil
      result(false)
    case .notDetermined:
      break
    @unknown default:
      pendingLocationPermissionResult = nil
      result(false)
    }
  }
}
