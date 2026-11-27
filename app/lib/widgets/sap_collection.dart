// What SAP says is to collect, on the Collections page and on a customer's
// Record Collection page (the user, 27 Nov 2026: once Manna invoices, show
// the amount there). Figures are SAP's - see core/sap_invoices.dart.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit.dart' show inr;
import 'package:manna_field_sales/core/sap_invoices.dart';
import 'package:manna_field_sales/core/utils.dart' show today;
import 'package:manna_field_sales/services/api.dart';

const _red = Color(0xFFC62828);
const _muted = Colors.black54;

Widget _invoiceRow(Map<String, dynamic> inv, {bool showCustomer = false}) {
  final late = invoiceOverdue(inv, today());
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              showCustomer
                  ? '${inv['customer'] ?? ''}'
                  : 'Invoice ${inv['invoice_no'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
              [
                if (showCustomer) 'Invoice ${inv['invoice_no'] ?? ''}',
                dmy(inv['posting_date']),
                if (dmy(inv['due_date']).isNotEmpty)
                  '${late ? 'was due' : 'due'} ${dmy(inv['due_date'])}',
                'of ${inr((inv['total'] as num?) ?? 0)}',
              ].where((s) => s.isNotEmpty).join(' · '),
              style: TextStyle(fontSize: 12, color: late ? _red : _muted)),
        ]),
      ),
      Text(inr((inv['balance'] as num?) ?? 0),
          style: TextStyle(
              fontWeight: FontWeight.bold, color: late ? _red : null)),
    ]),
  );
}

Widget _totalLine(double amount, int count) => Row(children: [
      const Icon(Icons.receipt_long, color: Color(0xFFF46A21)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
            count == 0
                // Says what SAP sent, not "nothing to collect": until the
                // invoices sync writes, the mirror is empty for everyone.
                ? 'No open invoice from SAP'
                : 'To collect: ${inr(amount)}  ·  $count open invoice${count == 1 ? '' : 's'}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    ]);

/// The Collections page's top card: every open Manna Treads invoice of this
/// rep's customers (a manager's: the team's), oldest due first.
class SapToCollectCard extends StatefulWidget {
  const SapToCollectCard({super.key});
  @override
  State<SapToCollectCard> createState() => _SapToCollectCardState();
}

class _SapToCollectCardState extends State<SapToCollectCard> {
  late final Future<List<Map<String, dynamic>>> _f = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final customers = (await Api.getCustomers())
        .map((c) => '${c['name'] ?? ''}')
        .where((n) => n.isNotEmpty)
        .toList();
    return openInvoicesByDue(await Api.getOpenSapInvoices(customers));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _f,
      builder: (_, snap) {
        // Quiet while loading or when it cannot be read: the rep's own
        // collections below still work, and nothing may say the network is
        // gone.
        if (!snap.hasData) return const SizedBox.shrink();
        final rows = snap.data!;
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: ExpansionTile(
            title: _totalLine(toCollect(rows), rows.length),
            subtitle: const Text('From Manna Treads SAP invoices',
                style: TextStyle(fontSize: 12, color: _muted)),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in rows) _invoiceRow(r, showCustomer: true),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One customer's open invoices and the payments SAP has received from them,
/// above the form on their Record Collection page.
class SapCustomerCollection extends StatefulWidget {
  final String customer;
  const SapCustomerCollection({super.key, required this.customer});
  @override
  State<SapCustomerCollection> createState() => _SapCustomerCollectionState();
}

class _SapCustomerCollectionState extends State<SapCustomerCollection> {
  late final Future<List<List<Map<String, dynamic>>>> _f = Future.wait([
    Api.getSapInvoicesFor(widget.customer),
    Api.getSapPaymentsFor(widget.customer)
        .catchError((_) => <Map<String, dynamic>>[]),
  ]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<List<Map<String, dynamic>>>>(
      future: _f,
      builder: (_, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final open = openInvoicesByDue(snap.data![0]);
        final paid = snap.data![1]
            .where((p) => '${p['status'] ?? ''}' != 'Cancelled')
            .take(5)
            .toList();
        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _totalLine(toCollect(open), open.length),
                  const SizedBox(height: 4),
                  for (final r in open) _invoiceRow(r),
                  if (paid.isNotEmpty) ...[
                    const Divider(),
                    const Text('Received in SAP',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    for (final p in paid)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Expanded(
                            child: Text(
                                [
                                  dmy(p['posting_date']),
                                  if ('${p['mode'] ?? ''}'.isNotEmpty &&
                                      '${p['mode']}' != 'null')
                                    '${p['mode']}',
                                  'Receipt ${p['payment_no'] ?? ''}',
                                ].join(' · '),
                                style: const TextStyle(
                                    fontSize: 12, color: _muted)),
                          ),
                          Text(inr((p['amount'] as num?) ?? 0),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF2E7D32))),
                        ]),
                      ),
                  ],
                ]),
          ),
        );
      },
    );
  }
}
