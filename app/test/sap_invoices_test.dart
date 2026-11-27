// What a rep has to collect, from SAP's invoices (27 Nov 2026).

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sap_invoices.dart';

Map<String, dynamic> inv(String no, String status, num balance,
        {String due = '2026-12-01'}) =>
    {
      'invoice_no': no,
      'status': status,
      'balance': balance,
      'total': balance,
      'paid': 0,
      'due_date': due,
    };

void main() {
  test('the amount to collect is the open balances summed', () {
    expect(toCollect([inv('1', 'Open', 1000), inv('2', 'Open', 250.5)]), 1250.5);
  });

  test('a closed invoice is not money to collect, whatever its balance', () {
    expect(toCollect([inv('1', 'Closed', 1000), inv('2', 'Open', 300)]), 300);
  });

  test('a balance under a rupee is rounding, not money to chase', () {
    expect(invoiceOpen(inv('1', 'Open', 0.4)), isFalse);
    expect(toCollect([inv('1', 'Open', 0.4)]), 0);
  });

  test('an invoice past its due date with money on it is overdue', () {
    expect(invoiceOverdue(inv('1', 'Open', 500, due: '2026-11-20'), '2026-11-27'),
        isTrue);
    expect(invoiceOverdue(inv('1', 'Open', 500, due: '2026-11-27'), '2026-11-27'),
        isFalse);
  });

  test('a paid or undated invoice is never called overdue', () {
    expect(invoiceOverdue(inv('1', 'Closed', 0, due: '2026-10-01'), '2026-11-27'),
        isFalse);
    expect(invoiceOverdue(inv('1', 'Open', 500, due: ''), '2026-11-27'), isFalse);
  });

  test('open invoices are listed oldest due date first', () {
    final rows = openInvoicesByDue([
      inv('late', 'Open', 10, due: '2026-12-20'),
      inv('done', 'Closed', 0, due: '2026-10-01'),
      inv('early', 'Open', 10, due: '2026-11-01'),
    ]);
    expect(rows.map((r) => r['invoice_no']), ['early', 'late']);
  });

  test('dates read day-month-year', () {
    expect(dmy('2026-11-23'), '23-11-2026');
    expect(dmy(null), '');
  });
}
