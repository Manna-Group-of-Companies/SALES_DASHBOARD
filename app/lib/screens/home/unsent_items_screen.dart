// Field work kept with no signal, waiting to be sent (11 Nov 2026): the
// outbox — collections, expenses, complaints, leave, answers, locations, edits.
//
// Like Unsent Punches, a rep never has to come here: everything goes by itself
// when the signal returns. It is for seeing that something is safely kept, and
// for one the server would not take, which stays here with the reason until
// the rep sends it again or throws it away.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/outbox.dart';

class UnsentItemsScreen extends StatefulWidget {
  const UnsentItemsScreen({super.key});
  @override
  State<UnsentItemsScreen> createState() => _UnsentItemsScreenState();
}

class _UnsentItemsScreenState extends State<UnsentItemsScreen> {
  List<OutboxItem> _items = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await Outbox.all();
    if (mounted) {
      setState(() {
        _items = list;
        _loading = false;
      });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 5)));

  Future<void> _sendNow() async {
    setState(() => _sending = true);
    final ready = await Api.recoverAfterOfflineStart();
    final r = ready
        ? await Outbox.flush(Api.sendOutboxItem, describe: humanError)
        : const OutboxResult(0, [], true);
    if (!mounted) return;
    setState(() => _sending = false);
    await _load();
    if (!mounted) return;
    if (r.stoppedOffline && r.sent == 0) {
      _snack('Still no signal. Saved here.');
    } else if (r.failed.isNotEmpty) {
      _snack('Sent ${r.sent}; ${r.failed.length} not sent.');
    } else if (r.sent > 0) {
      _snack('Sent ${r.sent} ✓');
    }
  }

  Future<void> _discard(OutboxItem i) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this?'),
        content: Text('${i.label} was never sent. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    if (yes != true) return;
    await Outbox.discard(i.id);
    await _load();
  }

  static IconData _icon(String kind) => switch (kind) {
        'collection' => Icons.payments_outlined,
        'expense' => Icons.receipt_long_outlined,
        'complaint' => Icons.report_problem_outlined,
        'leave' => Icons.event_busy_outlined,
        'regularization' => Icons.schedule,
        'item_request' => Icons.add_box_outlined,
        'condition_answer' => Icons.reply,
        'customer_location' || 'customer_site' => Icons.place_outlined,
        _ => Icons.edit_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Waiting to Send')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _banner(),
                      const SizedBox(height: 8),
                      for (final i in _items) _card(i),
                    ],
                  ),
                ),
      bottomNavigationBar: _items.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _sending ? null : _sendNow,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _sending
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Send now'),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _empty() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_done_outlined, size: 56, color: Colors.black26),
            SizedBox(height: 16),
            Text('Everything has been sent',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('Work saved without signal waits here.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.black54)),
          ]),
        ),
      );

  Widget _banner() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4E5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD9A8)),
        ),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 20, color: Color(0xFFB35309)),
          SizedBox(width: 10),
          Expanded(
            child: Text('Not sent yet. They send by themselves when you have signal.',
                style: TextStyle(fontSize: 12.5, height: 1.4)),
          ),
        ]),
      );

  Widget _card(OutboxItem i) {
    final age = daysSince(i.savedAt.toIso8601String());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_icon(i.kind), size: 20, color: const Color(0xFFF46A21)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(i.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Saved ${age == 0 ? 'today' : '$age day${age == 1 ? '' : 's'} ago'}'
            '${i.files.isNotEmpty ? '  ·  with photo' : ''}',
            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
          ),
          if (i.lastError != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(8),
              ),
              // A refused item is not resent by itself; the rep decides.
              child: Text(
                  'Last try: ${i.lastError}'
                  '${i.refused ? '\nNot sent by itself: press Send now to try again, or discard it.' : ''}',
                  style: const TextStyle(fontSize: 12, height: 1.35)),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _sending ? null : () => _discard(i),
              child: const Text('Discard', style: TextStyle(color: Colors.redAccent)),
            ),
          ),
        ]),
      ),
    );
  }
}
