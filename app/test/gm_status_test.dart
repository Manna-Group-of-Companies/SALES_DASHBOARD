import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/widgets/gm_status.dart';

void main() {
  test('an order the manager escalated shows the rep "Sent to GM"', () {
    expect(gmStatusOf('Pending GM Approval')?.label, 'Sent to GM');
  });

  test('an order the GM approved shows the rep "GM approved"', () {
    expect(gmStatusOf('Pending Final Approval')?.label, 'GM approved');
  });

  test('no GM tag on any other status', () {
    for (final s in ['Pending Approval', 'PO Approved - Ready for SAP', 'Rejected', '']) {
      expect(gmStatusOf(s), isNull, reason: s);
    }
  });

  Future<void> show(WidgetTester t, Widget? w) =>
      t.pumpWidget(MaterialApp(home: Scaffold(body: w ?? const SizedBox())));

  testWidgets('one tick until the manager opens it, two ticks after',
      (t) async {
    await show(t, approvalTicks('Pending Approval', null));
    expect(find.text('Sent to manager'), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);

    await show(t, approvalTicks('Pending Approval', '2026-11-10 11:18:25'));
    expect(find.text('Seen by manager'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  testWidgets('an escalated order reads "Sent to GM", whether seen or not',
      (t) async {
    await show(t, approvalTicks('Pending GM Approval', '2026-11-10 11:18:25'));
    expect(find.text('Sent to GM'), findsOneWidget);
  });

  test('no ticks once the order is decided', () {
    expect(approvalTicks('PO Approved - Ready for SAP', '2026-11-10'), isNull);
    expect(approvalTicks('Rejected', null), isNull);
  });
}
