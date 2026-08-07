import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/approval.dart';
import 'package:manna_field_sales/screens/manager/manager_order_review_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class GMApprovalsScreen extends StatefulWidget {
  const GMApprovalsScreen({super.key});
  @override
  State<GMApprovalsScreen> createState() => _GMApprovalsScreenState();
}

class _GMApprovalsScreenState extends State<GMApprovalsScreen> {
  late Future<List<Approval>> _future;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _reload() => setState(() { _future = _load(); });

  Future<List<Approval>> _load() async {
    final res = await Future.wait([
      Api.getPendingGMSalesOrderPOs(),
      Api.getPendingGMLeadOrderPOs(),
    ]);
    final out = <Approval>[];
    for (final r in res[0]) {
      out.add(Approval('Customer PO — GM approval', r['name'],
          r['custom_sales_person'], r['customer'], (r['grand_total'] ?? 0),
          'gm_so_po'));
    }
    for (final r in res[1]) {
      out.add(Approval('Lead PO — GM approval', r['name'], r['sales_person'],
          r['lead_name'], (r['total_amount'] ?? 0), 'gm_lead_po'));
    }
    // These reach the GM because the customer would go past their credit
    // limit, so the credit picture is the decision — what they owe now, what
    // this order adds, and what the limit was. Without all three the GM is
    // being asked to approve a number with nothing to weigh it against.
    await Future.wait(out.map((a) async {
      if (a.kind != 'gm_so_po') return;
      final party = (a.party ?? '').toString();
      if (party.isEmpty) return;
      try {
        a.custOutstanding = await Api.getCustomerOutstanding(party);
        a.custLimit = await Api.getCustomerCreditLimit(party);
      } catch (_) {
        // A missing figure must not hide the approval. It is shown as unknown
        // rather than as zero, which would read as "owes nothing".
      }
      a.orderTotal = (a.amount is num) ? (a.amount as num).toDouble() : 0;
    }));
    return out;
  }

  /// One figure of the credit picture.
  Widget _fig(String label, double value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          Text('₹${value.toStringAsFixed(0)}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
        ]),
      );

  /// Opens the full order review, where the GM can change anything — the
  /// lines, the quantities, the rate, the delivery date — before deciding.
  Future<void> _open(Approval a) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ManagerOrderReviewScreen(
                orderName: a.name, isLead: a.kind == 'gm_lead_po')));
    _reload();
  }

  Future<void> _act(Approval a, bool approve) async {
    try {
      if (a.kind == 'gm_so_po') {
        await Api.approveSalesOrderPO(a.name, approve);
      } else {
        await Api.approveLeadOrderPO(a.name, approve);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${approve ? 'Approved (Ready for SAP)' : 'Rejected'} ${a.name}')));
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(humanError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GM Approvals'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Approval>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text(humanError(snap.error)));
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('No POs awaiting GM approval 🎉'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final a = items[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                              child: Text(a.title,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold))),
                          Text('₹${a.amount}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 4),
                        Text('${a.name}  ·  ${a.party ?? ''}'),
                        Text('Rep: ${a.rep ?? '—'}',
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 12)),
                        // The credit picture, which is the whole reason this
                        // reached the GM. Projected is the number that matters:
                        // the question is not what they owe now but what they
                        // will owe once this ships.
                        if (a.kind == 'gm_so_po') ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: const Color(0xFFFFF1F0),
                                borderRadius: BorderRadius.circular(6)),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _fig('Owes now', a.custOutstanding),
                                  _fig('This order', a.orderTotal),
                                  _fig('Would owe',
                                      a.custOutstanding + a.orderTotal,
                                      bold: true),
                                  _fig('Credit limit', a.custLimit),
                                  const SizedBox(height: 2),
                                  Text(
                                      a.custLimit > 0
                                          ? 'Over by ₹${((a.custOutstanding + a.orderTotal) - a.custLimit).toStringAsFixed(0)}'
                                          : 'No credit limit set for this customer.',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFFB3261E))),
                                ]),
                          ),
                        ],
                        const SizedBox(height: 8),
                        // Approving here is a credit decision, not a review of
                        // the order. Opening it gives the GM the lines, the
                        // stock position and the ability to change anything.
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _open(a),
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('Open the order'),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(
                              child: FilledButton.icon(
                                  onPressed: () => _act(a, true),
                                  icon: const Icon(Icons.check),
                                  label: const Text('Approve'))),
                          const SizedBox(width: 8),
                          Expanded(
                              child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red),
                                  onPressed: () => _act(a, false),
                                  icon: const Icon(Icons.close),
                                  label: const Text('Reject'))),
                        ]),
                      ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// -------------------- ATTENDANCE CALENDAR --------------------
