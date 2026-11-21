// The product lines a rep picks from (17 Nov 2026): the new price-list names
// with the old quality in brackets. manna_item_request refuses any line not in
// its LINES list, so every one the phone offers must be there - and the old
// names must stay, for requests already queued on a phone.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/item_request.dart';

void main() {
  final server = File('server/item_request.py').readAsStringSync();
  final linesBlock = RegExp(r'LINES = \[([\s\S]*?)\]').firstMatch(server)!.group(1)!;
  final accepted = RegExp(r'"([^"]+)"').allMatches(linesBlock).map((m) => m.group(1)!).toSet();

  test('every line the phone offers is one the server accepts', () {
    for (final l in kItemRequestLines) {
      expect(accepted, contains(l), reason: l);
    }
  });

  test('the new names carry the old quality in brackets', () {
    expect(kItemRequestLines.first, 'Manna Double Blue (Black Pearl)');
    expect(kItemRequestLines, containsAll(['Manna Blue (Platinum)', 'Rox (Silver)', 'Verdo (Polygold & Diamond)']));
  });

  test('the old names are still accepted, for requests queued before the update', () {
    expect(accepted, containsAll(['Black Pearl', 'Platinum', 'Silver', 'Polygold', 'Diamond', 'Hot']));
  });
}
