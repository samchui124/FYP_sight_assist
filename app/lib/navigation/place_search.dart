import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class PlaceSuggestion {
  const PlaceSuggestion({
    required this.placeId,
    required this.primaryText,
    required this.secondaryText,
  });

  final String placeId;
  final String primaryText;
  final String secondaryText;

  String get displayText =>
      secondaryText.isEmpty ? primaryText : '$primaryText, $secondaryText';

  factory PlaceSuggestion.fromJson(Map<String, Object?> json) {
    final placeId = json['placeId'];
    final text = json['text'];
    final structuredFormat = json['structuredFormat'];
    if (placeId is! String ||
        placeId.isEmpty ||
        text is! Map<String, Object?> ||
        structuredFormat is! Map<String, Object?>) {
      throw const FormatException('Invalid Google Places suggestion');
    }

    final primary = structuredFormat['mainText'];
    final secondary = structuredFormat['secondaryText'];
    if (primary is! Map<String, Object?> ||
        primary['text'] is! String ||
        (secondary != null &&
            (secondary is! Map<String, Object?> ||
                secondary['text'] is! String))) {
      throw const FormatException('Invalid Google Places suggestion text');
    }

    return PlaceSuggestion(
      placeId: placeId,
      primaryText: primary['text']! as String,
      secondaryText: secondary == null
          ? ''
          : (secondary as Map<String, Object?>)['text']! as String,
    );
  }
}

class PlaceSearchException implements Exception {
  const PlaceSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PlaceSearch {
  PlaceSearch({
    required this.apiKey,
    required this._client,
    TargetPlatform? platform,
    String? androidCertificateSha1,
  }) : _platform = platform ?? defaultTargetPlatform,
       _androidCertificateSha1 =
           (androidCertificateSha1 ?? _defaultAndroidCertificateSha1)
               .replaceAll(':', '')
               .toUpperCase();

  static const String _defaultAndroidCertificateSha1 = String.fromEnvironment(
    'ANDROID_CERT_SHA1',
  );

  static const String _fieldMask =
      'suggestions.placePrediction.placeId,'
      'suggestions.placePrediction.text.text,'
      'suggestions.placePrediction.structuredFormat.mainText.text,'
      'suggestions.placePrediction.structuredFormat.secondaryText.text';

  final String apiKey;
  final http.Client _client;
  final TargetPlatform _platform;
  final String _androidCertificateSha1;

  String? _sessionToken;

  Future<List<PlaceSuggestion>> search(String query) async {
    if (apiKey.isEmpty) {
      throw const PlaceSearchException(
        'Place search is not configured. Add a restricted Places API key.',
      );
    }
    final normalizedQuery = query.trim();
    if (normalizedQuery.length < 2) return const <PlaceSuggestion>[];

    final response = await _client.post(
      Uri.https('places.googleapis.com', '/v1/places:autocomplete'),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': _fieldMask,
        ..._applicationHeaders(),
      },
      body: jsonEncode(<String, Object?>{
        'input': normalizedQuery,
        'languageCode': 'zh-HK',
        'includedRegionCodes': <String>['hk'],
        'sessionToken': _sessionToken ??= _newSessionToken(),
      }),
    );

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const PlaceSearchException(
        'Google Places returned an unreadable response.',
      );
    }
    if (response.statusCode != 200) {
      final error = decoded is Map<String, Object?> ? decoded['error'] : null;
      final message = error is Map<String, Object?> ? error['message'] : null;
      throw PlaceSearchException(
        message is String && message.isNotEmpty
            ? message
            : 'Google Places request failed (${response.statusCode}).',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const PlaceSearchException(
        'Google Places returned an unexpected response.',
      );
    }

    final suggestions = decoded['suggestions'];
    if (suggestions is! List<Object?>) {
      throw const PlaceSearchException(
        'Google Places returned an unexpected suggestions list.',
      );
    }
    return suggestions
        .whereType<Map<String, Object?>>()
        .map((suggestion) => suggestion['placePrediction'])
        .whereType<Map<String, Object?>>()
        .map(PlaceSuggestion.fromJson)
        .toList(growable: false);
  }

  void closeSession() {
    _sessionToken = null;
  }

  void dispose() {
    _client.close();
  }

  Map<String, String> _applicationHeaders() {
    switch (_platform) {
      case TargetPlatform.iOS:
        return <String, String>{
          'X-Ios-Bundle-Identifier': 'hk.pathguide.pathguide',
        };
      case TargetPlatform.android:
        if (_androidCertificateSha1.isEmpty) return const <String, String>{};
        return <String, String>{
          'X-Android-Package': 'hk.pathguide.pathguide',
          'X-Android-Cert': _androidCertificateSha1,
        };
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return const <String, String>{};
    }
  }

  String _newSessionToken() {
    final random = Random.secure();
    final hex = List<String>.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
      growable: false,
    ).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '4${hex.substring(13, 16)}-'
        '${(8 + random.nextInt(4)).toRadixString(16)}${hex.substring(17, 20)}-'
        '${hex.substring(20)}';
  }
}
