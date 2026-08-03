// The process cycle a line moves through, and the one thing that must never
// break when the real stage lists replace the placeholders.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/production_stages.dart';
import 'package:manna_field_sales/models/product_category.dart';

void main() {
  group('Stage sequences', () {
    test('each family has its own cycle', () {
      final pctr = stagesFor(ProductCategory.pctr);
      final ctr = stagesFor(ProductCategory.ctr);
      final bg = stagesFor(ProductCategory.bondingGum);
      final vs = stagesFor(ProductCategory.vulcanizingSolution);
      // Whatever the real steps turn out to be, four families sharing one list
      // would mean the per-category requirement was never implemented.
      expect({pctr, ctr, bg, vs}.length, 4);
    });

    test('every cycle starts unstarted and ends dispatched', () {
      for (final c in ProductCategory.values) {
        final s = stagesFor(c);
        expect(s.first, kStageNotStarted, reason: '$c');
        expect(s.last, kStageDispatched, reason: '$c');
      }
    });

    test('the label lookup agrees with the category lookup', () {
      // The production screens only have the stored category string, not the
      // Item, so these two must not drift apart.
      expect(stagesForLabel('PCTR'), stagesFor(ProductCategory.pctr));
      expect(stagesForLabel('CTR'), stagesFor(ProductCategory.ctr));
      expect(stagesForLabel('Bonding Gum'),
          stagesFor(ProductCategory.bondingGum));
      expect(stagesForLabel('Vulcanizing Solution'),
          stagesFor(ProductCategory.vulcanizingSolution));
    });

    test('an unknown label falls back rather than throwing', () {
      expect(stagesForLabel(null), stagesFor(ProductCategory.other));
      expect(stagesForLabel('Something Else'),
          stagesFor(ProductCategory.other));
    });
  });

  group('Progress', () {
    final stages = stagesFor(ProductCategory.pctr);

    test('an untouched line reads as the first stage', () {
      expect(stageIndex(stages, null), 0);
      expect(stageIndex(stages, ''), 0);
      expect(stageProgress(stages, null), 0);
    });

    test('a dispatched line is complete', () {
      expect(stageProgress(stages, kStageDispatched), 1.0);
      expect(isDispatched(kStageDispatched), isTrue);
      expect(isDispatched('Curing'), isFalse);
    });

    test('a mid-cycle stage sits between the two', () {
      final p = stageProgress(stages, 'Curing');
      expect(p, greaterThan(0));
      expect(p, lessThan(1));
    });

    test('a stage that no longer exists is flagged, not silently zeroed', () {
      // This is the case that matters when the real stage lists land: orders
      // already running must not quietly reset to "Not Started".
      expect(stageIndex(stages, 'Some Retired Stage'), -1);
      expect(stageProgress(stages, 'Some Retired Stage'), 0);
    });
  });
}
