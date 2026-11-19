// The order screen's search: the short forms reps say at the counter, and
// sizes that find the one item typed.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/product_search.dart';

void main() {
  const bp = 'TREAD RUBBER PRECURED BLACK PEARL 130 VK 90';
  const pl = 'PCTR MANNA BLUE AJAX 102 60 (PLATINUM)';
  const bg = 'BONDING GUM 1KG';

  bool m(String q, String name, [String code = 'FG-1']) =>
      productMatchesSearch(q, name, code);

  test('bp finds Black Pearl, which has no "bp" in its name', () {
    expect(m('bp', bp), isTrue);
    expect(m('bp', pl), isFalse);
  });

  test('pl finds Platinum', () {
    expect(m('pl', pl), isTrue);
    expect(m('PL', pl), isTrue);
  });

  test('bg finds Bonding Gum', () {
    expect(m('bg', bg), isTrue);
    expect(m('bg', bp), isFalse);
  });

  test('si, md, pg and dm find Silver, Medium, Poly Gold and Diamond', () {
    expect(m('si', 'TREAD RUBBER HOT SILVER 34*12'), isTrue);
    expect(m('md', 'TREAD RUBBER PRECURED MEDIUM 120 VK 70'), isTrue);
    expect(m('pg', 'TREAD RUBBER HOT POLY GOLD 34*12'), isTrue);
    expect(m('pg', 'TREAD RUBBER HOT POLYGOLD 34*12'), isTrue);
    // How some Poly Gold items were imported.
    expect(m('pg', 'TREAD RUBBER HOT POLYCOLD 34*12'), isTrue);
    expect(m('dm', 'TREAD RUBBER PRECURED DIAMOND 130 VK 90'), isTrue);
    expect(m('dm', bp), isFalse);
  });

  // 19 Nov 2026: "34 12" brought up every name with a 34 or a 12 anywhere in
  // it — 134, 340, 120. A size typed is that size only.
  const items = [
    'TREAD RUBBER HOT BLACK 34*12',
    'TREAD RUBBER HOT BLACK 34*14',
    'TREAD RUBBER HOT BLACK 134*12',
    'TREAD RUBBER HOT BLACK 34*120',
    'TREAD RUBBER HOT PLATINUM 34*12',
    'TREAD RUBBER PRECURED BLACK PEARL 130 VK 90',
  ];

  /// What the order screen shows: the products found at the strictest level
  /// that found any.
  List<String> shown(String q) {
    final lv = {for (final n in items) n: productSearchLevel(q, n, 'FG-1')};
    final hits = lv.values.whereType<int>();
    if (hits.isEmpty) return const [];
    final best = hits.reduce((a, b) => a < b ? a : b);
    return items.where((n) => lv[n] == best).toList();
  }

  test('a size finds that size only, not numbers that contain it', () {
    expect(shown('bl 34 12'), ['TREAD RUBBER HOT BLACK 34*12']);
  });

  // 19 Nov 2026, the user: however it is typed, the product must show.
  group('however it is typed, the product still shows', () {
    test('with no spaces, or with x or * between the sizes', () {
      for (final q in ['3412', '34x12', '34X12', '34*12', '34 x 12']) {
        expect(shown(q), contains('TREAD RUBBER HOT PLATINUM 34*12'),
            reason: q);
      }
    });

    test('half a number while typing still shows something', () {
      expect(shown('13'), [
        'TREAD RUBBER HOT BLACK 134*12',
        'TREAD RUBBER PRECURED BLACK PEARL 130 VK 90',
      ]);
    });

    test('a short form glued to a size', () {
      expect(shown('bp130'), ['TREAD RUBBER PRECURED BLACK PEARL 130 VK 90']);
      expect(shown('pl34'), ['TREAD RUBBER HOT PLATINUM 34*12']);
    });

    test('part of a word, not just its start', () {
      expect(shown('pearl'), ['TREAD RUBBER PRECURED BLACK PEARL 130 VK 90']);
      expect(shown('tinum'), ['TREAD RUBBER HOT PLATINUM 34*12']);
    });

    test('something that is in no name still finds nothing', () {
      expect(shown('zzz'), isEmpty);
    });
  });

  test('a size is read the same however the name writes it', () {
    expect(m('34 12', 'TREAD RUBBER HOT PLATINUM 34 X 12'), isTrue);
    expect(m('34 12', 'TREAD RUBBER HOT PLATINUM 34X12'), isTrue);
    expect(m('130 vk', 'PRECURED BLACK PEARL 130VK 90'), isTrue);
  });

  test('a short form combines with a size, in either order', () {
    expect(m('bp 130', bp), isTrue);
    expect(m('130 bp', bp), isTrue);
    expect(m('bp 205', bp), isFalse);
  });

  test('the full words and the item code still work as before', () {
    expect(m('black pearl', bp), isTrue);
    expect(m('blue ajax', pl), isTrue);
    expect(m('fg-3', bg, 'FG-3'), isTrue);
    expect(m('silver', bp), isFalse);
  });
}
