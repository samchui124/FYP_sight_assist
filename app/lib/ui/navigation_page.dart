import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/app_strings.dart';
import '../navigation/place_search.dart';

const String _mapsApiKey = String.fromEnvironment('MAPS_API_KEY');
const String _placesApiKey = String.fromEnvironment('PLACES_API_KEY');
const MethodChannel _navigationPermissionChannel = MethodChannel(
  'hk.pathguide/navigation_permissions',
);

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key});

  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  final PlaceSearch _placeSearch = PlaceSearch(
    apiKey: _placesApiKey,
    client: http.Client(),
  );
  final SpeechToText _speech = SpeechToText();
  final TextEditingController _destinationController = TextEditingController();
  final FocusNode _destinationFocus = FocusNode();

  Timer? _searchDebounce;
  List<PlaceSuggestion> _suggestions = const <PlaceSuggestion>[];
  String? _searchError;
  String? _navigationError;
  int _searchGeneration = 0;
  bool _searching = false;
  bool _startingNavigation = false;
  bool _navigationStarted = false;
  bool _navigationSessionInitialized = false;
  bool _listening = false;
  bool _speechInitialized = false;
  PlaceSuggestion? _selectedPlace;
  Completer<void>? _locationWaiter;

  AppStrings get _strings => AppStrings.current;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _placeSearch.closeSession();
    _placeSearch.dispose();
    _destinationController.dispose();
    _destinationFocus.dispose();
    if (_speechInitialized) unawaited(_speech.cancel());
    final locationWaiter = _locationWaiter;
    if (locationWaiter != null && !locationWaiter.isCompleted) {
      locationWaiter.complete();
    }
    if (_navigationSessionInitialized) {
      unawaited(_cleanupNavigation());
    }
    super.dispose();
  }

  Future<void> _onQueryChanged(String query) async {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.trim().length < 2) {
      _placeSearch.closeSession();
      setState(() {
        _suggestions = const <PlaceSuggestion>[];
        _searchError = null;
        _searching = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _searchError = null;
      _suggestions = const <PlaceSuggestion>[];
    });
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_searchPlaces(query, generation));
    });
  }

  Future<void> _searchPlaces(String query, int generation) async {
    try {
      final results = await _placeSearch.search(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _suggestions = results;
        _searchError = results.isEmpty ? _strings.navigationNoResults : null;
        _searching = false;
      });
    } on PlaceSearchException catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _suggestions = const <PlaceSuggestion>[];
        _searchError = error.message;
        _searching = false;
      });
    } on Exception catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _suggestions = const <PlaceSuggestion>[];
        _searchError = '${_strings.navigationSearchFailed} $error';
        _searching = false;
      });
    }
  }

  Future<void> _toggleSpeechInput() async {
    if (_speech.isListening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    setState(() {
      _searchError = null;
      _listening = true;
    });
    try {
      final available = await _speech.initialize(
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _searchError = error.errorMsg;
          });
        },
      );
      if (!mounted) return;
      if (!available) {
        setState(() {
          _listening = false;
          _searchError = _strings.noSpeechResult;
        });
        return;
      }
      _speechInitialized = true;

      final locale = await _speech.systemLocale();
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: locale?.localeId,
          listenFor: const Duration(seconds: 12),
          pauseFor: const Duration(seconds: 3),
          listenMode: ListenMode.search,
        ),
        onResult: _onSpeechResult,
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _searchError = error.message ?? _strings.noSpeechResult;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _searchError = '${_strings.noSpeechResult} $error';
      });
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final words = result.recognizedWords.trim();
    if (!mounted || words.isEmpty) return;
    _destinationController.value = TextEditingValue(
      text: words,
      selection: TextSelection.collapsed(offset: words.length),
    );
    unawaited(_onQueryChanged(words));
    if (result.finalResult) setState(() => _listening = false);
  }

  Future<void> _startNavigation(PlaceSuggestion place) async {
    if (_startingNavigation) return;
    _destinationFocus.unfocus();
    setState(() {
      _selectedPlace = place;
      _startingNavigation = true;
      _navigationError = null;
      _searchError = null;
      _suggestions = const <PlaceSuggestion>[];
    });

    try {
      if (_mapsApiKey.isEmpty) {
        throw StateError(_strings.googleMapsKeyMissing);
      }
      final locationGranted = await _navigationPermissionChannel
          .invokeMethod<bool>('requestLocation');
      if (locationGranted != true) {
        throw StateError(_strings.locationPermissionDenied);
      }
      if (!mounted) return;

      if (!await GoogleMapsNavigator.areTermsAccepted()) {
        final accepted = await GoogleMapsNavigator.showTermsAndConditionsDialog(
          _strings.appTitle,
          _strings.appTitle,
        );
        if (!accepted) throw StateError(_strings.navigationRouteFailed);
      }
      if (!mounted) return;

      await GoogleMapsNavigator.initializeNavigationSession();
      _navigationSessionInitialized = true;
      if (!mounted) {
        await _cleanupNavigation();
        return;
      }
      setState(() => _navigationError = _strings.navigationLocationWaiting);
      await _waitForCurrentLocation();
      if (!mounted) {
        await _cleanupNavigation();
        return;
      }

      final routeStatus = await GoogleMapsNavigator.setDestinations(
        Destinations(
          waypoints: <NavigationWaypoint>[
            NavigationWaypoint.withPlaceID(
              title: place.displayText,
              placeID: place.placeId,
            ),
          ],
          displayOptions: NavigationDisplayOptions(),
          routingOptions: RoutingOptions(
            travelMode: NavigationTravelMode.walking,
          ),
        ),
      );
      if (routeStatus != NavigationRouteStatus.statusOk) {
        throw StateError('${_strings.navigationRouteFailed} ($routeStatus)');
      }
      if (!mounted) {
        await _cleanupNavigation();
        return;
      }
      await GoogleMapsNavigator.startGuidance();
      _placeSearch.closeSession();
      if (!mounted) {
        await _cleanupNavigation();
        return;
      }
      setState(() {
        _navigationStarted = true;
        _startingNavigation = false;
        _navigationError = null;
      });
    } on Exception catch (error) {
      await _cleanupNavigation();
      if (!mounted) return;
      setState(() {
        _startingNavigation = false;
        _navigationStarted = false;
        _navigationError = error is StateError
            ? error.toString().replaceFirst('Bad state: ', '')
            : '${_strings.navigationRouteFailed} $error';
      });
    }
  }

  Future<void> _waitForCurrentLocation() async {
    final location = Completer<void>();
    _locationWaiter = location;
    StreamSubscription<RoadSnappedLocationUpdatedEvent>? subscription;
    try {
      subscription =
          await GoogleMapsNavigator.setRoadSnappedLocationUpdatedListener((_) {
            if (!location.isCompleted) location.complete();
          });
      await location.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw StateError(_strings.navigationLocationWaiting);
    } finally {
      _locationWaiter = null;
      await subscription?.cancel();
    }
  }

  Future<void> _cleanupNavigation() async {
    try {
      await GoogleMapsNavigator.cleanup();
    } on Exception catch (error) {
      debugPrint(
        '[PathGuide navigation] Failed to clean up navigation: $error',
      );
    } finally {
      _navigationSessionInitialized = false;
    }
  }

  Future<void> _stopNavigation() async {
    if (_navigationSessionInitialized) await _cleanupNavigation();
    if (!mounted) return;
    setState(() {
      _navigationStarted = false;
      _startingNavigation = false;
      _navigationError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
              child: Row(
                children: <Widget>[
                  IconButton(
                    onPressed: _startingNavigation
                        ? null
                        : () => Navigator.of(context).pop(),
                    tooltip: strings.backToHome,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Text(
                      strings.navigation,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_navigationStarted)
              Expanded(child: _navigationMap())
            else
              Expanded(child: _destinationEntry()),
            if (_navigationStarted) _navigationFooter(),
          ],
        ),
      ),
    );
  }

  Widget _destinationEntry() {
    final strings = _strings;
    final missingKeys = <String>[
      if (_mapsApiKey.isEmpty) strings.googleMapsKeyMissing,
      if (_placesApiKey.isEmpty) strings.googlePlacesKeyMissing,
    ];
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _destinationController,
            focusNode: _destinationFocus,
            enabled: _placesApiKey.isNotEmpty && !_startingNavigation,
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            decoration: InputDecoration(
              labelText: strings.destination,
              hintText: strings.destinationHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: _listening
                    ? strings.stopListening
                    : strings.speakDestination,
                onPressed: _startingNavigation || _placesApiKey.isEmpty
                    ? null
                    : _toggleSpeechInput,
                icon: Icon(
                  _listening ? Icons.mic : Icons.mic_none,
                  color: _listening ? Colors.redAccent : null,
                ),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (missingKeys.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _messageCard(missingKeys.join('\n')),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: _messageCard(strings.navigationSafetyNotice),
        ),
        if (_startingNavigation)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _navigationError ?? strings.navigationPreparing,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
          )
        else if (_navigationError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _messageCard(_navigationError!),
          ),
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _searchError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        Expanded(
          child: ListView.separated(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: _suggestions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final suggestion = _suggestions[index];
              return Semantics(
                button: true,
                child: ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(suggestion.primaryText),
                  subtitle: suggestion.secondaryText.isEmpty
                      ? null
                      : Text(suggestion.secondaryText),
                  onTap: _startingNavigation
                      ? null
                      : () => _startNavigation(suggestion),
                ),
              );
            },
          ),
        ),
        if (_suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              label: strings.googlePlacesAttribution,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Image.asset(
                  'assets/images/powered-by-google.png',
                  width: 120,
                  height: 14,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _navigationMap() {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GoogleMapsNavigationView(
            initialNavigationUIEnabledPreference:
                NavigationUIEnabledPreference.automatic,
            onViewCreated: (controller) {
              unawaited(_configureNavigationView(controller));
            },
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: 12,
          child: _messageCard(_strings.navigationSafetyNotice),
        ),
        if (_navigationError != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: _messageCard(_navigationError!),
          ),
      ],
    );
  }

  Future<void> _configureNavigationView(
    GoogleNavigationViewController controller,
  ) async {
    try {
      await controller.setMyLocationEnabled(true);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _navigationError = error.message ?? _strings.navigationRouteFailed;
        });
      }
    }
  }

  Widget _navigationFooter() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_selectedPlace != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${_strings.destination}: ${_selectedPlace!.displayText}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _stopNavigation,
              icon: const Icon(Icons.stop),
              label: Text(_strings.stopGuidance),
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageCard(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF242A31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF68737F)),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, height: 1.4),
      ),
    );
  }
}
