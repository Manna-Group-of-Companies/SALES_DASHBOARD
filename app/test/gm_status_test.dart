import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/widgets/gm_status.dart';

void main() {
  const promise = 'Cheque for 50,000 on Friday';

  test('an over-credit order waiting on the manager shows "With manager"', () {
    for (final s in ['Pending Approval', 'PO Uploaded - Pending Approval', 'Pending Rate Approval']) {
      expect(gmStatusOf(s, commitment: promise)?.label, 'With manager', reason: s);
    }
  });

  test('an order the manager escalated shows the rep "With GM"', () {
    expect(gmStatusOf('Pending GM Approval')?.label, 'With GM');
    expect(gmStatusOf('Pending GM Approval', commitment: promise)?.label, 'With GM');
  });

  test('an order the GM approved shows the rep "GM approved"', () {
    expect(gmStatusOf('Pending Final Approval', commitment: promise)?.label, 'GM approved');
  });

  test('an order within the limit waiting on the manager has no tag', () {
    for (final c in [null, '', '   ', 'null']) {
      expect(gmStatusOf('Pending Approval', commitment: c), isNull, reason: '$c');
    }
  });

  test('no tag once the order is decided, promise or not', () {
    for (final s in ['PO Approved - Ready for SAP', 'Rejected', '']) {
      expect(gmStatusOf(s, commitment: promise), isNull, reason: s);
    }
  });

  testWidgets('the order page says whose desk it is on', (t) async {
    Future<void> banner(String po) => t.pumpWidget(MaterialApp(
        home: Scaffold(body: GmBanner(poStatus: po, commitment: promise))));
    await banner('Pending Approval');
    expect(find.text('With manager'), findsOneWidget);
    expect(find.textContaining('send it to the GM'), findsOneWidget);
    await banner('Pending GM Approval');
    expect(find.text('With GM'), findsOneWidget);
    expect(find.textContaining('Waiting for the GM'), findsOneWidget);
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

  testWidgets('an escalated order reads "With GM", whether seen or not',
      (t) async {
    await show(t, approvalTicks('Pending GM Approval', '2026-11-10 11:18:25'));
    expect(find.text('With GM'), findsOneWidget);
  });

  test('no ticks once the order is decided', () {
    expect(approvalTicks('PO Approved - Ready for SAP', '2026-11-10'), isNull);
    expect(approvalTicks('Rejected', null), isNull);
  });
}
