import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/models/approval.dart';
import 'package:manna_field_sales/services/api.dart';

class ManagerApprovalsScreen extends StatefulWidget {
  const ManagerApprovalsScreen({super.key});
  @override
  State<ManagerApprovalsScreen> createState() => _ManagerApprovalsScreenState();
}

class _ManagerApprovalsScreenState extends State<ManagerApprovalsScreen> {
  late Future<List<Approval>> _future;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _reload() => setState(() { _future = _load(); });

  /// Everything the manager owes a decision on **except orders**.
  ///
  /// Orders live in Team Orders and only there. Approving one fixes a price
  /// permanently, commits stock, and — for a lead — converts the party, so it
  /// belongs on a screen built to show what that decision rests on, not mixed
  /// in with location photos to verify. Two places to look was two places to
  /// miss one.
  Future<List<Approval>> _load() async {
    final res = await Future.wait([
      Api.getPendingProformaReleases(),
      Api.getPendingLocationVerifications(),
      Api.getPendingSiteVerifications(),
      Api.getPendingLeadLocationVerifications(),
    ]);
    final out = <Approval>[];
    for (final r in res[0]) {
      out.add(Approval('Proforma credit release', r['name'],
          r['custom_sales_person'], r['customer'], (r['grand_total'] ?? 0),
          'proforma'));
    }
    for (final r in res[1]) {
      out.add(Approval(
          'Location verification', r['name'],
          r['custom_location_captured_by'],
          r['customer_name'] ?? r['name'], null, 'location',
          lat: r['custom_latitude'], lng: r['custom_longitude'],
          image: r['custom_banner_photo']?.toString()));
    }
    for (final r in res[2]) {
      out.add(Approval('Site: ${r['site_name']} (${r['customer']})', r['name'],
          r['captured_by'], r['customer'], null, 'site',
          lat: r['latitude'], lng: r['longitude'],
          image: r['banner_photo']?.toString()));
    }
    for (final r in res[3]) {
      out.add(Approval(
          'Lead location verification', r['name'],
          r['custom_location_captured_by'],
          r['lead_name'] ?? r['name'], null, 'lead_location',
          lat: r['custom_latitude'], lng: r['custom_longitude'],
          image: r['custom_banner_photo']?.toString()));
    }

    // The outstanding-limit enrichment and escalation flag that used to run
    // here went with the orders. Nothing left on this screen turns on a rep's
    // credit position.
    return out;
  }

  // The order review lived here. It is reached from Team Orders now, which is
  // the only place an order is decided.

  /// A lead order cannot be approved until the lead carries what an invoice
  /// will need. Checked at the moment of approval, against the live lead
  /// rather than whatever the list was loaded with.
  Future<bool> _leadIsComplete(Approval a) async {
    final leadName = '${a.party ?? ''}';
    if (leadName.isEmpty) return true;
    List<String> missing;
    try {
      final lead = await Api.getLeadDoc(leadName);
      missing = missingLeadDetails(lead);
    } catch (_) {
      return true; // Do not block a decision on a failed lookup.
    }
    if (missing.isEmpty) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Lead details missing'),
        content: Text(
            'This lead becomes a customer as soon as it is invoiced, and an '
            'invoice needs:\n\n'
            '${missing.map((m) => '  •  $m').join('\n')}\n\n'
            'Ask ${a.rep ?? 'the rep'} to complete the lead, then approve.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
    return false;
  }

  Future<void> _act(Approval a, bool approve) async {
    try {
      switch (a.kind) {
        case 'lead_order':
          if (approve && !await _leadIsComplete(a)) return;
          final customer = await Api.approveLeadOrder(a.name, approve);
          if (customer != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Lead converted to customer: $customer'),
                duration: const Duration(seconds: 5)));
          }
          break;
        case 'so_po':
          if (approve && a.escalate) {
            await Api.escalateSalesOrderPOToGM(a.name);
          } else {
            await Api.approveSalesOrderPO(a.name, approve);
          }
          break;
        case 'lead_po':
          if (approve && a.escalate) {
            await Api.escalateLeadOrderPOToGM(a.name);
          } else {
            await Api.approveLeadOrderPO(a.name, approve);
          }
          break;
        case 'proforma':
          await Api.releaseProforma(a.name, approve);
          break;
        case 'location':
          await Api.approveLocation(a.name, approve, a.lat, a.lng);
          break;
        case 'site':
          await Api.approveSite(a.name, approve, a.lat, a.lng);
          break;
        case 'lead_location':
          await Api.approveLeadLocation(a.name, approve, a.lat, a.lng);
          break;
      }
      if (mounted) {
        final msg = (approve && a.escalate)
            ? 'Sent to GM for approval: ${a.name}'
            : '${approve ? 'Approved' : 'Rejected'} ${a.name}';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
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
      appBar: AppBar(title: const Text('Approvals'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<List<Approval>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(humanError(snap.error))));
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('No pending approvals 🎉'));
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
                          if (a.amount != null)
                            Text('Rs ${a.amount}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 4),
                        Text('${a.name}  ·  ${a.party ?? ''}'),
                        Text('Rep: ${a.rep ?? '—'}',
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 12)),
                        if (a.kind == 'so_po' || a.kind == 'lead_po') ...[
                          const SizedBox(height: 6),
                          if (a.kind == 'so_po')
                            Text(
                                'Customer outstanding: ₹${a.custOutstanding.toStringAsFixed(0)}',
                                style: const TextStyle(fontSize: 12)),
                          Text(
                              'Rep outstanding: ₹${a.repOutstanding.toStringAsFixed(0)}'
                                  '${a.repLimit > 0 ? '  /  limit ₹${a.repLimit.toStringAsFixed(0)}' : '  /  no limit set'}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: a.escalate
                                      ? Colors.red
                                      : Colors.black87,
                                  fontWeight: a.escalate
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          if (a.escalate)
                            Container(
                              margin: const EdgeInsets.only(top: 6),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                  color: const Color(0xFFFFF3E0),
                                  borderRadius: BorderRadius.circular(6)),
                              child: const Text(
                                  '⚠ Rep is over the outstanding limit. Approving sends this to the General Manager for final approval.',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.deepOrange)),
                            ),
                        ],
                        if ((a.image ?? '').isNotEmpty &&
                            (a.kind == 'location' ||
                                a.kind == 'site' ||
                                a.kind == 'lead_location'))
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                (a.image ?? '').startsWith('http')
                                    ? a.image!
                                    : '${Session.I.baseUrl}${a.image}',
                                height: 170,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                headers: Session.I.authHeaders,
                                errorBuilder: (_, __, ___) => Container(
                                    height: 60,
                                    alignment: Alignment.center,
                                    child: const Text('(photo unavailable)',
                                        style:
                                        TextStyle(color: Colors.black45))),
                                loadingBuilder: (c, w, p) => p == null
                                    ? w
                                    : Container(
                                    height: 170,
                                    alignment: Alignment.center,
                                    child:
                                    const CircularProgressIndicator()),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        // A Sales Order is not a yes/no on a card. Approving it
                        // fixes the price permanently and commits stock, so it
                        // goes through the review screen where the manager can
                        // actually see what they are agreeing to.
                        // A lead order commits the same stock and fixes the
                        // same rates as a customer order, and approving it
                        // converts the lead as well — even less of a yes/no on
                        // a card than a Sales Order is.
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

