// Orders typed with no signal, waiting to be sent.
//
// Everything on this screen is phrased as "not sent yet" rather than as an
// order, because that is what it is. The rep is the one standing in front of
// the customer, so they are the one who has to know the difference between an
// order the factory has and a note on a phone.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/pending_orders.dart';

class UnsentOrdersScreen extends StatefulWidget {
  const UnsentOrdersScreen({super.key});
  @override
  State<UnsentOrdersScreen> createState() => _UnsentOrdersScreenState();
}

class _UnsentOrdersScreenState extends State<UnsentOrdersScreen> {
  List<PendingOrder> _drafts = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await PendingOrders.all();
    if (mounted) {
      setState(() {
        _drafts = list;
        _loading = false;
      });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 5)));

  Future<void> _sendAll() async {
    setState(() => _sending = true);
    final result = await PendingOrders.sendAll(
      (draft) async {
        final company = await Api.getCompany();
        return Api.placeOrder(
          customer: draft.customer,
          company: company,
          items: draft.items,
          deliveryDate: draft.deliveryDate,
          reservations: draft.reservations,
        );
      },
      describe: humanError,
    );

    if (!mounted) return;
    setState(() => _sending = false);
    await _load();
    if (!mounted) return;

    if (result.sent.isEmpty) {
      _snack(result.failed.isEmpty
          ? 'Nothing to send.'
          : result.failed.first.lastError ?? 'Could not send.');
      return;
    }
    if (result.allSent) {
      _snack('Sent ${result.sent.length} order'
          '${result.sent.length == 1 ? '' : 's'} ✓');
      // A single order is worth opening — the rep wants its number.
      if (result.sent.length == 1 && mounted) {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => OrderDetailScreen(orderName: result.sent.first)));
      }
      return;
    }
    _snack('Sent ${result.sent.length}, ${result.failed.length} still waiting.');
  }

  Future<void> _discard(PendingOrder draft) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this order?'),
        content: Text('${draft.customerName} — this cannot be undone, and the '
            'order has never been sent.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (yes != true) return;
    await PendingOrders.remove(draft.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unsent Orders')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _drafts.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _banner(),
                      const SizedBox(height: 8),
                      for (final d in _drafts) _card(d),
                    ],
                  ),
                ),
      bottomNavigationBar: _drafts.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _sending ? null : _sendAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _sending
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('Send ${_drafts.length} order'
                            '${_drafts.length == 1 ? '' : 's'} now'),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _empty() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_done_outlined, size: 56, color: Colors.black26),
              SizedBox(height: 16),
              Text('Everything has been sent',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              Text(
                'Orders you take without signal are kept here until you can '
                'send them.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ],
          ),
        ),
      );

  Widget _banner() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4E5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD9A8)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 20, color: Color(0xFFB35309)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'These have not reached the office. No stock is held for them, '
                'and no order number exists until they are sent.',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
          ],
        ),
      );

  Widget _card(PendingOrder d) {
    final age = daysSince(d.savedAt.toIso8601String());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    d.customerName.isEmpty ? d.customer : d.customerName,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                Text('₹${d.total.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${d.items.length} item${d.items.length == 1 ? '' : 's'}  ·  '
              'for ${d.deliveryDate}  ·  '
              'typed ${age == 0 ? 'today' : '$age day${age == 1 ? '' : 's'} ago'}',
              style: const TextStyle(fontSize: 12.5, color: Colors.black54),
            ),
            if (d.needsStock) ...[
              const SizedBox(height: 8),
              const Text(
                'Draws on minimum stock — not held until sent',
                style: TextStyle(
                    fontSize: 12, color: Color(0xFFB35309),
                    fontWeight: FontWeight.w600),
              ),
            ],
            if (d.lastError != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Last try: ${d.lastError}',
                    style: const TextStyle(fontSize: 12, height: 1.35)),
              ),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _sending ? null : () => _discard(d),
                child: const Text('Discard',
                    style: TextStyle(color: Colors.redAccent)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
