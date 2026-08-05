// The process cycle a line moves through, and the one thing that must never
// break when the real stage lists replace the placeholders.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/production_stages.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/api.dart';

void main() {
  _orderRollUp();
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

// The order-level status the sales side reads.
//
// Production moves stages per item; the manager's order list and review read a
// single order-level field. Nothing was writing it, so an order the factory had
// put into Curing still read "Not Started" to everyone outside the factory.
void _orderRollUp() {
  Map<String, dynamic> line(String category, String? stage) => {
        'custom_product_category': category,
        if (stage != null) 'custom_production_stage': stage,
      };

  group('Rolling item stages up to the order', () {
    test('an untouched order reads Not Started', () {
      expect(Api.rollUpStage([line('PCTR', null)]), 'Not Started');
    });

    test('a started line puts the order In Production', () {
      expect(Api.rollUpStage([line('PCTR', 'Curing')]), 'In Production');
    });

    test('one packed line and one untouched is not Ready', () {
      // Work has begun, so it is not Not Started — but calling it Ready while
      // half the order has not been touched would be a lie to the sales side.
      expect(
          Api.rollUpStage([
            line('PCTR', 'Packed'),
            line('PCTR', null),
          ]),
          'In Production');
    });

    test('every line packed reads Ready', () {
      expect(
          Api.rollUpStage([
            line('PCTR', 'Packed'),
            line('CTR', 'Packed'),
          ]),
          'Ready');
    });

    test('every line dispatched reads Dispatched', () {
      expect(
          Api.rollUpStage([
            line('PCTR', kStageDispatched),
            line('CTR', kStageDispatched),
          ]),
          'Dispatched');
    });

    test('one line still packed keeps the order off Dispatched', () {
      expect(
          Api.rollUpStage([
            line('PCTR', kStageDispatched),
            line('CTR', 'Packed'),
          ]),
          'Ready');
    });

    test('a retired stage does not make an order look Ready', () {
      // A stage revised out of the sequence counts as unknown, not finished,
      // so it holds the order back rather than letting it read Ready.
      expect(
          Api.rollUpStage([
            line('PCTR', 'Some Retired Stage'),
            line('PCTR', 'Packed'),
          ]),
          'In Production');
    });

    test('an order with no lines is Not Started, not blank', () {
      expect(Api.rollUpStage(const []), 'Not Started');
    });

    test('only the four Select values are ever produced', () {
      // custom_production_status is a Select; anything else is rejected by
      // Frappe and the stage update fails outright.
      const allowed = {'Not Started', 'In Production', 'Ready', 'Dispatched'};
      for (final s in ['Compound Mixing', 'Extrusion', 'Curing', 'Trimming',
        'Quality Check', 'Packed', kStageDispatched, '', 'Nonsense']) {
        expect(allowed, contains(Api.rollUpStage([line('PCTR', s)])),
            reason: 'stage "" produced a value the field will not accept');
      }
    });
  });
}
