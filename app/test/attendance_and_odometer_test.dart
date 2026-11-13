// Two field bugs the user reported on 13 Nov 2026: reps "punched out by
// themselves" soon after punching in (ATT-01248: out eight minutes after in),
// and odometer photos that never reached the web.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/attendance_rules.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/trip_rules.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/net_cache.dart';

class _Server implements HttpClientAdapter {
  final List<String> writes = [];
  List<Map<String, dynamic>> todays = [];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body,
      Future<void>? cancelFuture) async {
    final m = o.method.toUpperCase();
    final path = Uri.decodeComponent(o.path);
    Object data = {'message': 'ok'};
    if (m == 'GET' && path.endsWith('/api/resource/Attendance Log')) {
      data = {'data': todays};
    } else if (m == 'POST' && path.endsWith('/api/resource/Attendance Log')) {
      writes.add('POST');
      data = {
        'data': {'name': 'ATT-NEW'}
      };
    }
    return ResponseBody.fromString(jsonEncode(data), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('A punch-out is never one stray tap', () {
    final now = DateTime(2026, 11, 12, 18, 40);

    test('punched in minutes ago, the rep is told it was only minutes', () {
      final q = punchOutQuestion('2026-11-12 18:31:56', now);
      expect(q, contains('only 8 min ago'));
      expect(q, contains('18:31'));
      expect(q, contains('Punch out now?'));
    });

    test('after a working day it reads as the end of one', () {
      final q = punchOutQuestion('2026-11-12 09:10:29', now);
      expect(q, contains('09:10, 9 h 29 min ago'));
      expect(q, isNot(contains('only')));
    });

    test('with no punch-in time on the card it still asks', () {
      expect(punchOutQuestion('', now), contains('Punch out now?'));
    });
  });

  group('One attendance record a day', () {
    late _Server server;
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('att');
      NetCache.debugRoot = dir;
      server = _Server();
      Session.I
        ..email = ''
        ..init();
      Session.I.dio.httpClientAdapter = server;
    });

    tearDown(() async {
      NetCache.debugRoot = null;
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a punch-in on a day that has a record is that record', () async {
      server.todays = [
        {'name': 'ATT-01248'}
      ];
      final name = await Api.punchIn(
          salesPerson: 'Prasad V',
          lat: 10.1,
          lng: 76.4,
          at: '2026-11-12 18:31:56');
      expect(name, 'ATT-01248');
      expect(server.writes, isEmpty, reason: 'no second record is made');
    });

    test('the first punch-in of a day makes the record', () async {
      final name = await Api.punchIn(
          salesPerson: 'Prasad V',
          lat: 10.1,
          lng: 76.4,
          at: '2026-11-12 09:00:00');
      expect(name, 'ATT-NEW');
      expect(server.writes, ['POST']);
    });
  });

  group('An odometer leg is not saved without its photo', () {
    test('a photo that failed, or was never taken, holds the leg', () {
      expect(
          canSaveOdometerLeg(
              odometerLeg: true, photoReady: false, uploading: false),
          isFalse);
    });

    test('a photo still on its way holds the leg', () {
      expect(
          canSaveOdometerLeg(
              odometerLeg: true, photoReady: false, uploading: true),
          isFalse);
    });

    test('a photo that went, or is kept to go, lets it be saved', () {
      expect(
          canSaveOdometerLeg(
              odometerLeg: true, photoReady: true, uploading: false),
          isTrue);
    });

    test('a bus or taxi leg has no odometer and needs no photo', () {
      expect(
          canSaveOdometerLeg(
              odometerLeg: false, photoReady: false, uploading: false),
          isTrue);
    });
  });
}
