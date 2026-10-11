// Manna Treads' SAP rates beside the rate box: reading what the Server Script
// `manna_customer_rates` answers, and the line shown under the box. The rule
// itself (special price, else Price List 01) lives in that script; this is the
// phone's reading of its answer. Pure Dart: no backend, no widgets.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/sap_rates.dart';

void main() {
  group("Manna Treads' SAP rates, as manna_customer_rates answers", () {
    // The live answer for the test dealer ZZ-TEST-A on 25 Sep 2026, trimmed,
    // with two entries that are not prices.
    final r = SapRates.fromMessage({
      'customer': 'ZZ TEST DEALER A - SYNC TEST - DO NOT USE',
      'bp_code': 'ZZ-TEST-A',
      'synced_at': '2026-09-25 20:30:52',
      'note': '',
      'rates': {
        'I-14636': {'rate': 199.0, 'source': 'special', 'list': 200.0},
        'I-14641': {'rate': 190, 'source': 'special', 'list': 190},
        'I-14637': {'rate': 185.0, 'source': 'list', 'list': 185.0},
        'ZERO': {'rate': 0, 'source': 'list'},
        'ODD': 'not a map',
      },
    });

    test('reads each item and drops what is not a price', () {
      expect(r.rates.keys.toSet(), {'I-14636', 'I-14641', 'I-14637'});
      expect(r['I-14636']!.rate, 199);
      expect(r['I-14636']!.isDealerPrice, isTrue);
      expect(r['I-14637']!.isDealerPrice, isFalse);
      expect(r.bpCode, 'ZZ-TEST-A');
      expect(r.syncedAt, '2026-09-25 20:30:52');
    });

    test("says whose price it is, and the list price when the dealer's differs", () {
      expect(r['I-14636']!.hint('kg'), "Manna Treads rate Rs 199/kg — this dealer's price (list Rs 200)");
      expect(r['I-14641']!.hint('kg'), "Manna Treads rate Rs 190/kg — this dealer's price");
      expect(r['I-14637']!.hint('kg'), 'Manna Treads list rate Rs 185/kg');
    });

    test('the locked box says the price comes from SAP and where to change it', () {
      expect(r['I-14636']!.fixedHint('kg'),
          "Manna Treads rate Rs 199/kg — this dealer's price (list Rs 200). Set in SAP — ask the office to change it.");
      expect(r['I-14637']!.fixedHint('kg'),
          'Manna Treads list rate Rs 185/kg. Set in SAP — ask the office to change it.');
    });

    test('keeps paise as SAP holds them — nothing is added or taken off', () {
      final p = SapRates.fromMessage({
        'rates': {'X': {'rate': 207.62, 'source': 'list', 'list': 207.62}},
      });
      expect(p['X']!.rate, 207.62);
      expect(p['X']!.hint('kg'), 'Manna Treads list rate Rs 207.62/kg');
    });

    test('an empty or odd answer is no rates, not a crash', () {
      expect(SapRates.fromMessage({}).isEmpty, isTrue);
      expect(SapRates.fromMessage({'rates': []}).isEmpty, isTrue);
      expect(SapRates.fromMessage({'rates': null, 'bp_code': null}).bpCode, '');
      expect(SapRates.none['I-14636'], isNull);
      expect(SapRates.none.listOnly, isFalse);
    });

    test("a customer's answer is not marked list-only", () {
      expect(r.listOnly, isFalse);
      expect(SapRates.fromMessage({'list_only': 0}).listOnly, isFalse);
    });
  });

  group('a lead is taken at the list price', () {
    // The live answer for the test lead CRM-LEAD-2026-04130 on 25 Sep 2026,
    // trimmed: Price List 01 only, and list_only set.
    final lead = SapRates.fromMessage({
      'customer': '',
      'lead': 'CRM-LEAD-2026-04130',
      'bp_code': '',
      'synced_at': '2026-09-25 20:30:52',
      'note': '',
      'list_only': 1,
      'rates': {
        'I-14636': {'rate': 200.0, 'source': 'list', 'list': 200.0},
      },
    });

    test('says the prices are the only ones the order may carry', () {
      expect(lead.listOnly, isTrue);
      expect(lead.lead, 'CRM-LEAD-2026-04130');
      expect(lead['I-14636']!.rate, 200);
      expect(lead['I-14636']!.isDealerPrice, isFalse);
    });

    test('reads list_only however the server writes it', () {
      expect(SapRates.fromMessage({'list_only': true}).listOnly, isTrue);
      expect(SapRates.fromMessage({'list_only': '1'}).listOnly, isTrue);
      expect(SapRates.fromMessage({'list_only': null}).listOnly, isFalse);
    });

    test('tells the rep where a lower price goes', () {
      expect(
          lead['I-14636']!.leadHint('kg'),
          'Lead order: Manna Treads list rate Rs 200/kg. '
          'A lower price goes through Higher Management once the lead is a customer.');
    });
  });
}
