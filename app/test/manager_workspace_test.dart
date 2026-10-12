// The manager workspace's own rules: which filter an order sits under, how
// money reads, and that an order card fits a phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sap_order_state.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/manager/manager_orders_screen.dart';
import 'package:manna_field_sales/screens/manager/manager_ui.dart';

void main() {
  setUp(() => Session.I.managedTeam = 'Pareeth');

  group('which filter an order sits under (twin of orderBucket in sapOrderState.ts)', () {
    test('cancelled in SAP outranks everything, approval included', () {
      expect(
          orderBucket(
              approved: true,
              poStatus: 'PO Approved - Ready for SAP',
              sap: const SapOrderState(salesOrderStatus: 'bost_Cancelled')),
          OrderBucket.cancelled);
    });

    test('a rejection outranks a stale approval flag', () {
      expect(
          orderBucket(
              approved: true,
              poStatus: 'Rejected',
              sap: const SapOrderState()),
          OrderBucket.rejected);
    });

    test('anything not decided is the manager\'s to approve', () {
      for (final s in ['Pending Approval', 'Pending GM Approval', 'Pending Final Approval', '']) {
        expect(orderBucket(approved: false, poStatus: s, sap: const SapOrderState()),
            OrderBucket.toApprove, reason: s);
      }
    });

    test('a Sales Order edited after approval is back to approve, rate flag or not', () {
      expect(
          bucketOf({
            'custom_po_status': 'Pending Approval',
            'custom_rate_approved': 1,
          }),
          OrderBucket.toApprove);
    });

    test('a lead order converted on the dashboard counts as approved', () {
      expect(
          bucketOf({'is_lead': true, 'status': 'Converted', 'custom_po_status': 'Converted'}),
          OrderBucket.approved);
    });
  });

  group('money', () {
    test('rupees group the Indian way', () {
      expect(money(1234567), '₹12,34,567');
      expect(money(999), '₹999');
      expect(money(-2500), '-₹2,500');
    });

    test('the UAE team reads dirhams in thousands', () {
      Session.I.managedTeam = 'Renjith';
      expect(money(1234567), 'AED 1,234,567');
      expect(moneyShort(85000), 'AED 85K');
    });

    test('tiles shorten to lakh and crore', () {
      expect(moneyShort(425000), '₹4.3L');
      expect(moneyShort(13000000), '₹1.3Cr');
    });
  });

  testWidgets('an order card with a long party name fits a small phone', (t) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          OrderCard(
            order: const {
              'name': 'SAL-ORD-2026-00155',
              'customer': 'Sree Narayana Tyre Retreading Works and Rubber Products Kozhikode',
              'custom_sales_person': 'Amjad Pr',
              'grand_total': 12345678,
              'transaction_date': '2026-10-11',
              'custom_po_status': 'Pending GM Approval',
              'custom_sap_sales_order': '485',
            },
            onTap: () {},
            trailingNote: const Text('12d'),
          ),
        ]),
      ),
    ));
    expect(t.takeException(), isNull);
    expect(find.text('SAP 485 · Amjad Pr · 11 Oct'), findsOneWidget);
  });
}
