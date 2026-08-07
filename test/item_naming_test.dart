// Reading quality and pattern out of an item name.
//
// Every name below is a real one from the catalogue. Parsing data out of a
// name is only safe while it is used for filtering and nothing else, so what
// these pin down is not just "it works" but "it fails harmlessly": an
// unrecognised name yields blanks and keeps its row, rather than vanishing
// from the list or being filed under the wrong grade.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/item_naming.dart';

void main() {
  group('the ordinary shape', () {
    test('grade, width, pattern', () {
      final p = parseItemName('TREAD RUBBER PRECURED BLACK PEARL 130 VK 90');
      expect(p.quality, 'BLACK PEARL');
      expect(p.pattern, 'VK');
    });

    test('a two-word pattern is not invented — only the token after the width',
        () {
      final p = parseItemName('TREAD RUBBER PRECURED BLACK PEARL 126 EAGLE 134');
      expect(p.quality, 'BLACK PEARL');
      expect(p.pattern, 'EAGLE');
    });

    test('a longer grade name survives', () {
      expect(parseItemName('TREAD RUBBER PRECURED TRACTOR PLATINUM 200 PM 120')
          .quality, 'TRACTOR PLATINUM');
    });

    test('the B sub-grade is kept distinct', () {
      // 13 of the 164 pools are "BLACK PEARL B". Folding them into BLACK PEARL
      // would quietly merge two things the office writes down separately.
      final p = parseItemName('TREAD RUBBER PRECURED BLACK PEARL B 124 SR 67');
      expect(p.quality, 'BLACK PEARL B');
      expect(p.pattern, 'SR');
    });
  });

  group('prefixes', () {
    test('each known prefix is stripped', () {
      for (final n in [
        'TREAD RUBBER PRECURED BLACK PEARL 130 VK 90',
        'PRECURED BLACK PEARL 130 VK 90',
        'PCTR BLACK PEARL 130 VK 90',
      ]) {
        expect(parseItemName(n).quality, 'BLACK PEARL', reason: n);
      }
    });

    test('the longest matching prefix wins', () {
      // "TREAD RUBBER " also matches, and would leave "PRECURED" as the grade.
      expect(
          parseItemName('TREAD RUBBER PRECURED BLACK PEARL 102 EA 60').quality,
          'BLACK PEARL');
    });

    test('a hot-rubber name parses too', () {
      final p = parseItemName('TREAD RUBBER HOT BIKE SF 30*8');
      expect(p.quality, 'BIKE SF');
    });
  });

  group('failing harmlessly', () {
    test('a name with no width yields blanks rather than nonsense', () {
      final p = parseItemName('BONDING GUM (DOMESTIC)');
      expect(p.quality, '');
      expect(p.pattern, '');
      expect(p.isEmpty, isTrue);
    });

    test('a name starting with its width still gives up its pattern', () {
      // "220 MXM 128 (MANNA)" has no grade written in it, but the pattern is
      // there and worth filtering on.
      final p = parseItemName('220 MXM 128 (MANNA)');
      expect(p.quality, '');
      expect(p.pattern, 'MXM');
    });

    test('mojibake does not contaminate the pattern', () {
      // A real name from the import: "...140 MSR 93Â€".
      expect(parseItemName('TREAD RUBBER PRECURED BLACK PEARL 140 MSR 93Â€')
          .pattern, 'MSR');
    });

    test('a width with nothing after it gives no pattern, not a crash', () {
      final p = parseItemName('TREAD RUBBER PRECURED BLACK PEARL 130');
      expect(p.quality, 'BLACK PEARL');
      expect(p.pattern, '');
    });

    test('two numbers running together give no pattern', () {
      expect(parseItemName('BLACK PEARL 130 90').pattern, '');
    });

    test('an empty name is handled', () {
      expect(parseItemName('').isEmpty, isTrue);
      expect(parseItemName('   ').isEmpty, isTrue);
    });
  });

  group('collecting the options', () {
    final names = [
      'TREAD RUBBER PRECURED BLACK PEARL 130 VK 90',
      'TREAD RUBBER PRECURED BLACK PEARL 120 AJAX 69',
      'TREAD RUBBER PRECURED BLACK PEARL B 124 SR 67',
      'TREAD RUBBER PRECURED BLACK PEARL 215 PM 132 LW',
      'BONDING GUM (DOMESTIC)',
    ];

    test('qualities are distinct and sorted, blanks dropped', () {
      expect(qualitiesIn(names), ['BLACK PEARL', 'BLACK PEARL B']);
    });

    test('patterns are distinct and sorted, blanks dropped', () {
      expect(patternsIn(names), ['AJAX', 'PM', 'SR', 'VK']);
    });

    test('an unparseable name adds no empty option to either list', () {
      // A blank entry in a dropdown is indistinguishable from "any", which is
      // already the first item.
      expect(qualitiesIn(names).contains(''), isFalse);
      expect(patternsIn(names).contains(''), isFalse);
    });
  });
}
