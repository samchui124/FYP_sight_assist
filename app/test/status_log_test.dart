import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/diag/status_log.dart';

/// 狀態檔的寫入行為。
///
/// 這裡測的不是「能不能寫檔」，而是兩件在真機上很貴的事：
/// 1. **節流真的有作用**——畫面 5 fps，不能每幀碰磁碟；
/// 2. **永遠只有一份快照**——這個 App 拍的是香港街頭，
///    累積歷史等於在使用者裝置上留一份「他走過哪裡」的紀錄，
///    那是本專案明確不該有的東西。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pathguide_status_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  StatusLog make({Duration interval = const Duration(seconds: 5)}) =>
      StatusLog(dir: dir.path, interval: interval);

  test('寫出可解析的檔案，且每次呼叫只留一份', () async {
    final log = make();
    final t0 = DateTime(2026, 10, 9, 12, 0, 0);

    await log.write(<String, Object?>{'frames': 1}, now: t0);
    final first = File(log.path);
    expect(first.existsSync(), isTrue);
    expect(first.readAsStringSync(), contains('"frames": 1'));

    await log.write(<String, Object?>{'frames': 2}, now: t0.add(const Duration(minutes: 1)));
    expect(first.readAsStringSync(), contains('"frames": 2'));
    expect(first.readAsStringSync(), isNot(contains('"frames": 1')));

    // 目錄裡不該有第二份快照或殘留的 .tmp。
    final files = dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList();
    expect(files.where((f) => f.endsWith('.json')).length, 1);
    expect(files.where((f) => f.endsWith('.tmp')), isEmpty,
        reason: 'rename 應該把暫存檔移走，不該留下半成品');
  });

  test('節流：間隔未到就不寫', () async {
    final log = make(interval: const Duration(seconds: 5));
    final t0 = DateTime(2026, 10, 9, 12, 0, 0);

    await log.maybeWrite(() => <String, Object?>{'n': 1}, now: t0);
    expect(log.writes, 1);

    await log.maybeWrite(() => <String, Object?>{'n': 2}, now: t0.add(const Duration(seconds: 2)));
    expect(log.writes, 1, reason: '不到 5 秒不該再寫');

    await log.maybeWrite(() => <String, Object?>{'n': 3}, now: t0.add(const Duration(seconds: 6)));
    expect(log.writes, 2);
    expect(File(log.path).readAsStringSync(), contains('"n": 3'));
  });

  test('shouldWrite 對第一次永遠為真', () {
    final log = make();
    expect(log.shouldWrite(DateTime(2026, 10, 9)), isTrue);
  });

  test('目錄不存在時自己建立（遞迴）', () async {
    final nested = StatusLog(
      dir: '${dir.path}${Platform.pathSeparator}a${Platform.pathSeparator}b',
    );
    await nested.write(<String, Object?>{'ok': true});

    expect(File(nested.path).existsSync(), isTrue);
  });

  test('各種值型別都能寫成合法 JSON 片段', () async {
    final log = make();
    await log.write(<String, Object?>{
      'int': 42,
      'double': 0.5,
      'bool': true,
      'null': null,
      'string': '引號"與反斜線\\',
      'list': <Object?>[1, 'a'],
      'map': <Object?, Object?>{'k': 1},
      'nan': double.nan,
    });

    final text = File(log.path).readAsStringSync();
    expect(text, contains('"int": 42'));
    expect(text, contains('"double": 0.500'));
    expect(text, contains('"bool": true'));
    expect(text, contains('"null": null'));
    expect(text, contains(r'引號\"與反斜線\\'));
    expect(text, contains('"list": [1, "a"]'));
    expect(text, contains('"map": {"k": 1}'));
    // NaN 不是合法 JSON，必須變成 null 而不是寫出 "NaN"。
    expect(text, contains('"nan": null'));
  });

  test('寫入失敗被吞掉，不拋給呼叫方', () async {
    // 用一個不可能建立的路徑（Windows 上的非法字元）。
    final bad = StatusLog(dir: '${dir.path}${Platform.pathSeparator}<>|bad');
    // 不該拋例外——診斷壞掉不該讓引導停下。
    await bad.write(<String, Object?>{'x': 1});
  });
}
