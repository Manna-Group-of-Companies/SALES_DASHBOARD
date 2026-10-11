// The GM's escalated-order card, laid out at a small phone's width.
//
// A card that overflows is a card the GM cannot act on, and the figures on it
// are the decision: what the customer owes, what this order adds, how far past
// the limit that goes. Rupees read the Indian way, as everywhere else.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/approval.dart';
import 'package:manna_field_sales/screens/manager/gm_approvals_screen.dart';

Approval _order({
  dynamic commitment = 'Will clear the 60-90 bucket by cheque on 15 Oct.',
  dynamic due = '2026-10-15',
  double owed = 615000,
  double limit = 500000,
  double total = 42629,
}) =>
    Approval('Customer PO — GM approval', 'SAL-ORD-2026-00151', 'Arjun K',
        'C-0412', total, 'gm_so_po',
        custOutstanding: owed,
        custLimit: limit,
        orderTotal: total,
        commitment: commitment,
        commitmentDue: due,
        partyName: 'Arun Traders Vadakara',
        placedOn: '2026-10-06');

Future<void> _pump(WidgetTester tester, Approval a, {double width = 320}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: GmEscalationCard(
          approval: a,
          today: DateTime(2026, 10, 8),
          onOpen: () {},
          onApprove: () {},
          onReject: () {},
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('lays out on a small phone without overflowing', (tester) async {
    await _pump(tester, _order());
    expect(tester.takeException(), isNull);
    expect(find.text('Arun Traders Vadakara'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Open the order'), findsOneWidget);
  });

  testWidgets('a customer with a long name and crores still fits', (tester) async {
    final a = _order(owed: 12345678, limit: 10000000, total: 987654)
      ..partyName = 'Sree Murugan Tyre Retreading and Rubber Works, Palakkad';
    await _pump(tester, a, width: 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows how far over the limit, in Indian grouping', (tester) async {
    await _pump(tester, _order());
    expect(find.text('₹42,629'), findsOneWidget); // this order
    expect(find.text('₹6,57,629'), findsOneWidget); // would owe
    expect(find.text('₹1,57,629'), findsOneWidget); // over by
    expect(find.text('Limit ₹5,00,000'), findsOneWidget);
    expect(find.textContaining('132% of the limit'), findsOneWidget);
  });

  testWidgets('says how long it has waited, and when the customer promised', (tester) async {
    await _pump(tester, _order());
    expect(find.text('Waiting 2 days'), findsOneWidget);
    expect(find.text('Promised by 15 Oct'), findsOneWidget);
  });

  testWidgets('no commitment is said, not left blank', (tester) async {
    await _pump(tester, _order(commitment: null, due: null));
    expect(find.text('No commitment from the customer.'), findsOneWidget);
    expect(find.textContaining('Promised by'), findsNothing);
  });

  testWidgets('within the limit shows the limit, never a negative overshoot', (tester) async {
    await _pump(tester, _order(owed: 100000, limit: 500000));
    expect(find.text('OVER BY'), findsNothing);
    expect(find.text('CREDIT LIMIT'), findsOneWidget);
    expect(find.textContaining('within the limit'), findsOneWidget);
    expect(find.textContaining('-₹'), findsNothing);
  });

  test('rupees group the Indian way', () {
    expect(GmEscalationCard.inr(0), '₹0');
    expect(GmEscalationCard.inr(999), '₹999');
    expect(GmEscalationCard.inr(1000), '₹1,000');
    expect(GmEscalationCard.inr(100000), '₹1,00,000');
    expect(GmEscalationCard.inr(12345678.4), '₹1,23,45,678');
    expect(GmEscalationCard.inr(-157629), '-₹1,57,629');
  });

  test('waiting time counts calendar days', () {
    final now = DateTime(2026, 10, 8, 9, 30);
    expect(GmEscalationCard.waited('2026-10-08', now), 'Raised today');
    expect(GmEscalationCard.waited('2026-10-07', now), 'Waiting 1 day');
    expect(GmEscalationCard.waited('2026-10-05', now), 'Waiting 3 days');
    expect(GmEscalationCard.waited('', now), '');
  });
}
