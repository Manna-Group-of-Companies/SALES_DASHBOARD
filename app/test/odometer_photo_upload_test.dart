// An odometer photo, and whether it actually reached the server.
//
// Until 14 September 2026 the leg dialogs ticked the photo button the moment the
// camera returned, uploaded only after the rep tapped Start, and swallowed any
// failure. A rep saw a tick and HR saw a leg with no photo. The tick now means
// the server has the file, and nothing short of that is allowed to look like it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/widgets/odometer_photo_upload.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Padding(
        padding: const EdgeInsets.all(16), child: child)));

/// The rep takes a photo; it lands at this path.
Future<String?> _takes(BuildContext _) async => '/photos/odo.jpg';

void main() {
  testWidgets('before a photo, it asks for one and claims nothing',
      (tester) async {
    await tester.pumpWidget(_host(OdometerPhotoUpload(
      label: 'Start odometer photo',
      shortLabel: 'Start photo',
      pick: _takes,
      upload: (_) async => '/private/files/start_odo.jpg',
      onUrl: (_) {},
    )));

    expect(find.text('Start odometer photo'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('no tick while the photo is still on its way', (tester) async {
    // The whole bug: a tick that appeared when the camera returned, before a
    // byte had left the phone.
    final server = Completer<String?>();
    final statuses = <OdometerPhotoStatus>[];
    await tester.pumpWidget(_host(OdometerPhotoUpload(
      label: 'Start odometer photo',
      shortLabel: 'Start photo',
      pick: _takes,
      upload: (_) => server.future,
      onUrl: (_) {},
      onStatus: statuses.add,
    )));

    await tester.tap(find.text('Start odometer photo'));
    await tester.pump();

    expect(find.text('Uploading start photo…'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    // The dialog holds its Start button on this.
    expect(statuses.last, OdometerPhotoStatus.uploading);

    server.complete('/private/files/start_odo.jpg');
    await tester.pumpAndSettle();
  });

  testWidgets('a green tick once the server has the file, and the url is handed over',
      (tester) async {
    String? url;
    await tester.pumpWidget(_host(OdometerPhotoUpload(
      label: 'End odometer photo',
      shortLabel: 'End photo',
      pick: _takes,
      upload: (_) async => '/private/files/end_odo.jpg',
      onUrl: (u) => url = u,
    )));

    await tester.tap(find.text('End odometer photo'));
    await tester.pumpAndSettle();

    expect(find.text('End photo uploaded'), findsOneWidget);
    final tick = tester.widget<Icon>(find.byIcon(Icons.check_circle));
    expect(tick.color, const Color(0xFF1B7F3B));
    expect(url, '/private/files/end_odo.jpg');
  });

  group('when the upload fails', () {
    testWidgets('says so, with the reason, and hands over no url',
        (tester) async {
      String? url = 'stale';
      final statuses = <OdometerPhotoStatus>[];
      await tester.pumpWidget(_host(OdometerPhotoUpload(
        label: 'Start odometer photo',
        shortLabel: 'Start photo',
        pick: _takes,
        upload: (_) async => throw Exception('No signal'),
        onUrl: (u) => url = u,
        onStatus: statuses.add,
      )));

      await tester.tap(find.text('Start odometer photo'));
      await tester.pumpAndSettle();

      expect(find.text('Start photo did not upload'), findsOneWidget);
      expect(find.textContaining('No signal'), findsOneWidget);
      // Told plainly what happens if they carry on, rather than finding out
      // from HR.
      expect(find.textContaining('saves without it'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(url, isNull);
      // Not held: a rep with no signal can still start the leg.
      expect(statuses.last, OdometerPhotoStatus.failed);
    });

    testWidgets('an answer with no file in it is a failure, not a success',
        (tester) async {
      // uploadFileGetUrl returns null rather than throwing when upload_file
      // answers with something other than a file. The old code saved the leg
      // on that just as silently as on an exception.
      String? url;
      await tester.pumpWidget(_host(OdometerPhotoUpload(
        label: 'Start odometer photo',
        shortLabel: 'Start photo',
        pick: _takes,
        upload: (_) async => null,
        onUrl: (u) => url = u,
      )));

      await tester.tap(find.text('Start odometer photo'));
      await tester.pumpAndSettle();

      expect(find.text('Start photo did not upload'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(url, isNull);
    });

    testWidgets('Retry sends the same photo again without reopening the camera',
        (tester) async {
      // The odometer may not read the same any more. The photo already taken
      // is the evidence; asking for a new one would lose it.
      var picks = 0;
      final sent = <String>[];
      var fail = true;
      String? url;
      await tester.pumpWidget(_host(OdometerPhotoUpload(
        label: 'Start odometer photo',
        shortLabel: 'Start photo',
        pick: (_) async {
          picks++;
          return '/photos/odo.jpg';
        },
        upload: (path) async {
          sent.add(path);
          if (fail) throw Exception('No signal');
          return '/private/files/start_odo.jpg';
        },
        onUrl: (u) => url = u,
      )));

      await tester.tap(find.text('Start odometer photo'));
      await tester.pumpAndSettle();
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(picks, 1);
      expect(sent, ['/photos/odo.jpg', '/photos/odo.jpg']);
      expect(find.text('Start photo uploaded'), findsOneWidget);
      expect(url, '/private/files/start_odo.jpg');
    });
  });

  testWidgets('a retake withdraws the old url until the new photo is up',
      (tester) async {
    // Otherwise Save during the retake would attach the photo the rep just
    // decided was wrong.
    final urls = <String?>[];
    final second = Completer<String?>();
    var n = 0;
    await tester.pumpWidget(_host(OdometerPhotoUpload(
      label: 'End odometer photo',
      shortLabel: 'End photo',
      pick: _takes,
      upload: (_) {
        n++;
        return n == 1 ? Future.value('/private/files/first.jpg') : second.future;
      },
      onUrl: urls.add,
    )));

    await tester.tap(find.text('End odometer photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retake'));
    await tester.pump();

    expect(urls.last, isNull);
    expect(find.byIcon(Icons.check_circle), findsNothing);

    second.complete('/private/files/second.jpg');
    await tester.pumpAndSettle();
    expect(urls.last, '/private/files/second.jpg');
  });

  testWidgets('editing a leg that already has a photo offers to replace it',
      (tester) async {
    await tester.pumpWidget(_host(OdometerPhotoUpload(
      label: 'Start odometer photo',
      shortLabel: 'Start photo',
      hasExisting: true,
      pick: _takes,
      upload: (_) async => '/private/files/start_odo.jpg',
      onUrl: (_) {},
    )));

    expect(find.text('Replace start photo'), findsOneWidget);
  });
}
