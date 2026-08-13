// What production changed since the reader last looked.
//
// Checked against `shared/fixtures/stage_watch.json`, the same file the
// dashboard's `client/src/domain/__tests__/stageWatch.test.ts` reads.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/stage_watch.dart';

Map<String, dynamic> _fixture() {
  // Relative to `app/`, which is where `flutter test` runs from.
  final f = File('../shared/fixtures/stage_watch.json');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

List<Map<String, dynamic>> _lines(dynamic v) =>
    (v as List).map((e) => (e as Map).cast<String, dynamic>()).toList();

StageSnapshot? _seen(dynamic v) =>
    v == null ? null : (v as Map).map((k, x) => MapEntry('$k', '$x'));

StagePart _part(String s) => s == 'made' ? StagePart.made : StagePart.shelf;

void main() {
  final fx = _fixture();

  group('shared fixture: the field names', () {
    test('watches the two fields the fixture names', () {
      final f = (fx['fields'] as Map).cast<String, dynamic>();
      expect(kStageFieldMade, f['made_part']);
      expect(kStageFieldShelf, f['shelf_part']);
    });
  });

  group('shared fixture: what changed', () {
    for (final raw in fx['changes'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final got = changesSince(_seen(c['seen']), _lines(c['lines']));
        final want = c['expect'] as List;
        expect(got.length, want.length);
        for (var i = 0; i < want.length; i++) {
          final w = (want[i] as Map).cast<String, dynamic>();
          expect(got[i].lineId, w['line_id']);
          expect(got[i].part, _part(w['part'] as String));
          expect(got[i].from, w['from']);
          expect(got[i].to, w['to']);
        }
      });
    }
  });

  group('shared fixture: the snapshot', () {
    for (final raw in fx['snapshot'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        expect(snapshotOf(_lines(c['lines'])), c['expect']);
      });
    }
  });

  // --------------------------------------------------- phone-side detail ---

  group('a first look establishes the baseline', () {
    test('reports nothing, then reports the next move', () {
      // The whole point: opening an order is not news. What happens after is.
      final lines = [
        {'name': 'row1', 'item_name': 'X', kStageFieldMade: 'Curing'}
      ];
      expect(changesSince(null, lines), isEmpty);

      final seen = snapshotOf(lines);
      final moved = [
        {'name': 'row1', 'item_name': 'X', kStageFieldMade: 'Packed'}
      ];
      expect(changesSince(seen, moved).length, 1);
    });

    test('does not repeat a change once it has been seen', () {
      final moved = [
        {'name': 'row1', 'item_name': 'X', kStageFieldMade: 'Packed'}
      ];
      expect(changesSince(snapshotOf(moved), moved), isEmpty);
    });
  });

  group('the ways Frappe returns an unset field', () {
    test('are all the same thing, and none of them is a change', () {
      const seen = {'row1': '|'};
      for (final v in [null, '', '   ', 'null', 'undefined']) {
        final lines = [
          {'name': 'row1', 'item_name': 'X', kStageFieldMade: v}
        ];
        expect(changesSince(seen, lines), isEmpty, reason: 'stage $v');
      }
    });
  });

  group('what the reader is shown', () {
    test('names which half of a split line moved', () {
      // The made half is left where it was, so only the shelf half is news.
      final c = changesSince({'row1': 'Cutting|Packed'}, [
        {
          'name': 'row1',
          'item_name': '160 SR 99',
          kStageFieldMade: 'Cutting',
          kStageFieldShelf: 'Dispatched',
        }
      ]);
      expect(c.length, 1);
      expect(describeChange(c.first), contains('from stock'));
      expect(describeChange(c.first), contains('Packed → Dispatched'));
    });

    test('says "Not started" rather than leaving a blank', () {
      expect(stageText(''), 'Not started');
      expect(stageText('Curing'), 'Curing');
      final c = changesSince({'row1': '|'}, [
        {'name': 'row1', 'item_name': 'X', kStageFieldMade: 'Cutting'}
      ]);
      expect(describeChange(c.first), contains('Not started → Cutting'));
    });

    test('collects the moved lines for highlighting, without duplicates', () {
      final c = changesSince({'row1': 'Cutting|Packed'}, [
        {
          'name': 'row1',
          'item_name': 'X',
          kStageFieldMade: 'Curing',
          kStageFieldShelf: 'Dispatched',
        }
      ]);
      expect(c.length, 2);
      expect(changedLineIds(c).toList(), ['row1']);
    });
  });

  group('an order whose lines were edited', () {
    test('reports neither the added nor the removed line as a stage change',
        () {
      const seen = {'row1': 'Curing|', 'row2': 'Cutting|'};
      final now = [
        {'name': 'row1', 'item_name': 'X', kStageFieldMade: 'Curing'},
        {'name': 'row3', 'item_name': 'Z', kStageFieldMade: 'Cutting'},
      ];
      expect(changesSince(seen, now), isEmpty);
    });

    test('ignores a row with no name rather than keying on nothing', () {
      expect(
          snapshotOf([
            {'item_name': 'X'}
          ]),
          isEmpty);
    });
  });
}
