// Item requests go to the rep's manager before the accountant (12 Nov 2026).
// The cases are shared with the dashboard: shared/fixtures/item_request_flow.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/item_request.dart';

void main() {
  final fixture = json.decode(File('../shared/fixtures/item_request_flow.json').readAsStringSync()) as Map;
  final cases = (fixture['cases'] as List).cast<Map>();

  group('item request stages (shared fixture)', () {
    for (final c in cases) {
      test('${c['why']}', () {
        final status = '${c['status']}';
        expect(itemRequestLabel(status), c['label']);
        expect(accountantAnswers(status), c['accountant_answers']);
      });
    }
  });

  test('a request read with no status is still with the manager', () {
    final r = ItemRequest.fromJson({'name': 'IREQ-1'});
    expect(r.label, 'With manager');
    expect(r.canApprove, isFalse);
  });

  test('only the server says a manager may approve', () {
    expect(ItemRequest.fromJson({'status': 'Pending Manager', 'can_approve': 1}).canApprove, isTrue);
    expect(ItemRequest.fromJson({'status': 'Pending Manager', 'can_approve': 0}).canApprove, isFalse);
    expect(ItemRequest.fromJson({'status': 'Pending Manager'}).canApprove, isFalse);
  });
}
