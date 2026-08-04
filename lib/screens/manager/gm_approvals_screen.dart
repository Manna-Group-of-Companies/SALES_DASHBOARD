import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/approval.dart';
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
    // outstanding context
    await Future.wait(out.map((a) async {
      final rep = (a.rep ?? '').toString();
      if (rep.isNotEmpty) {
        a.repOutstanding = await Api.getRepOutstanding(rep);
        a.repLimit = await Api.getRepOutstandingLimit(rep);
      }
      if (a.kind == 'gm_so_po') {
        a.custOutstanding =
        await Api.getCustomerOutstanding((a.party ?? '').toString());
      }
    }));
    return out;
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
            return Center(child: Text('Error: ${snap.error}'));
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
                        if (a.kind == 'gm_so_po')
                          Text(
                              'Customer outstanding: ₹${a.custOutstanding.toStringAsFixed(0)}',
                              style: const TextStyle(fontSize: 12)),
                        Text(
                            'Rep outstanding: ₹${a.repOutstanding.toStringAsFixed(0)}'
                                '${a.repLimit > 0 ? '  /  limit ₹${a.repLimit.toStringAsFixed(0)}' : ''}',
                            style: const TextStyle(
                                fontSize: 12,
                                color: Colors.red,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
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
