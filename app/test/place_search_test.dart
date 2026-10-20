import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pathguide/navigation/place_search.dart';

void main() {
  test('parses place suggestions with primary and secondary labels', () {
    final suggestion = PlaceSuggestion.fromJson(<String, Object?>{
      'placeId': 'place-123',
      'text': <String, Object?>{'text': 'Central Station'},
      'structuredFormat': <String, Object?>{
        'mainText': <String, Object?>{'text': 'Central Station'},
        'secondaryText': <String, Object?>{'text': 'Hong Kong'},
      },
    });

    expect(suggestion.placeId, 'place-123');
    expect(suggestion.displayText, 'Central Station, Hong Kong');
  });

  test(
    'sends a Hong Kong autocomplete request with a reusable session token',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{
            'suggestions': <Object?>[
              <String, Object?>{
                'placePrediction': <String, Object?>{
                  'placeId': 'place-123',
                  'text': <String, Object?>{'text': 'Central'},
                  'structuredFormat': <String, Object?>{
                    'mainText': <String, Object?>{'text': 'Central'},
                    'secondaryText': <String, Object?>{'text': 'Hong Kong'},
                  },
                },
              },
            ],
          }),
          200,
        );
      });
      final search = PlaceSearch(
        apiKey: 'restricted-test-key',
        client: client,
        platform: TargetPlatform.iOS,
      );

      final first = await search.search('Central');
      final second = await search.search('Central Station');

      expect(first.single.displayText, 'Central, Hong Kong');
      expect(second, hasLength(1));
      expect(requests.first.url.path, '/v1/places:autocomplete');
      expect(requests.first.headers['X-Goog-Api-Key'], 'restricted-test-key');
      expect(
        requests.first.headers['X-Ios-Bundle-Identifier'],
        'hk.pathguide.pathguide',
      );
      final firstBody = jsonDecode(requests.first.body) as Map<String, Object?>;
      final secondBody = jsonDecode(requests.last.body) as Map<String, Object?>;
      expect(firstBody['includedRegionCodes'], <String>['hk']);
      expect(firstBody['sessionToken'], secondBody['sessionToken']);

      search.closeSession();
      await search.search('Central');
      final thirdBody = jsonDecode(requests.last.body) as Map<String, Object?>;
      expect(thirdBody['sessionToken'], isNot(firstBody['sessionToken']));
      search.dispose();
    },
  );

  test(
    'reports a Places API error instead of returning empty results',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'message': 'API key is invalid'},
          }),
          403,
        ),
      );
      final search = PlaceSearch(apiKey: 'bad-key', client: client);

      await expectLater(
        search.search('Central'),
        throwsA(
          isA<PlaceSearchException>().having(
            (error) => error.message,
            'message',
            'API key is invalid',
          ),
        ),
      );
      search.dispose();
    },
  );

  test(
    'includes Android package and normalized certificate restrictions',
    () async {
      late http.Request receivedRequest;
      final client = MockClient((request) async {
        receivedRequest = request;
        return http.Response('{"suggestions":[]}', 200);
      });
      final search = PlaceSearch(
        apiKey: 'restricted-test-key',
        client: client,
        platform: TargetPlatform.android,
        androidCertificateSha1: 'aa:bb:cc',
      );

      await search.search('Central');

      expect(
        receivedRequest.headers['X-Android-Package'],
        'hk.pathguide.pathguide',
      );
      expect(receivedRequest.headers['X-Android-Cert'], 'AABBCC');
      search.dispose();
    },
  );

  test('fails clearly if no Places API key is configured', () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final search = PlaceSearch(apiKey: '', client: client);

    await expectLater(
      search.search('Central'),
      throwsA(isA<PlaceSearchException>()),
    );
    search.dispose();
  });
}
