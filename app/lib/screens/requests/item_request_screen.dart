// Item requests on the phone (10 Nov 2026): the rep asks for a product that is
// not in the catalogue and sees the accountant's answer (the new item code, or
// why not). From 12 Nov 2026 the rep's manager approves it first, on
// ItemRequestApprovalsScreen below. See core/item_request.dart.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/item_request.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/outbox.dart';

const Color _kOrange = Color(0xFFF46A21);
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  return m == null ? '' : '${m[3]} ${_months[int.parse(m[2]!) - 1]}';
}

/// The rep's item requests, newest first, and the way to make a new one.
class ItemRequestScreen extends StatefulWidget {
  const ItemRequestScreen({super.key});
  @override
  State<ItemRequestScreen> createState() => _ItemRequestScreenState();
}

class _ItemRequestScreenState extends State<ItemRequestScreen> {
  late Future<List<ItemRequest>> _future = Api.getItemRequests();

  Future<void> _new() async {
    final done = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const NewItemRequestScreen()));
    if (done == true && mounted) setState(() => _future = Api.getItemRequests());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Item Request')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _kOrange,
        foregroundColor: Colors.white,
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: const Text('New request'),
      ),
      body: FutureBuilder<List<ItemRequest>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final rows = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = Api.getItemRequests()),
            child: rows.isEmpty
                ? ListView(children: const [
                    Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No requests yet.'))),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _RequestCard(r: rows[i]),
                  ),
          );
        },
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final ItemRequest r;
  final bool showRep;
  final Widget? actions;
  const _RequestCard({required this.r, this.showRep = false, this.actions});

  @override
  Widget build(BuildContext context) {
    final color = switch (r.status) {
      'Done' => const Color(0xFF2E7D32),
      'Rejected' => Colors.red.shade700,
      kItemRequestWithAccountant => const Color(0xFF1565C0),
      _ => const Color(0xFFB26A00),
    };
    final qty = r.quantity > 0 ? '${trimQty(r.quantity)} ${r.unit}'.trim() : '';
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFE5E7EB))),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.title.isEmpty ? r.itemType : r.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
              child: Text(r.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              if (showRep && r.salesPerson.isNotEmpty) r.salesPerson,
              r.itemType,
              if (r.customerName.isNotEmpty) r.customerName,
              if (qty.isNotEmpty) qty,
              _date(r.requestedOn),
            ]
                .where((s) => s.isNotEmpty)
                .join('  ·  '),
            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
          ),
          if (r.status == 'Done' && r.itemCode.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Item code: ${r.itemCode}', style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2E7D32))),
          ],
          if (r.reply.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r.reply, style: TextStyle(fontSize: 13, color: r.status == 'Rejected' ? Colors.red.shade700 : Colors.black87)),
          ] else if (r.managerNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Manager: ${r.managerNote}', style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ],
          ?actions,
        ]),
      ),
    );
  }
}

/// The manager's (or the GM's) item requests to approve on to the accountant
/// (12 Nov 2026). The server says which ones this login may decide
/// (can_approve) and refuses the rest, so the screen only offers those.
class ItemRequestApprovalsScreen extends StatefulWidget {
  const ItemRequestApprovalsScreen({super.key});
  @override
  State<ItemRequestApprovalsScreen> createState() => _ItemRequestApprovalsScreenState();
}

class _ItemRequestApprovalsScreenState extends State<ItemRequestApprovalsScreen> {
  late Future<List<ItemRequest>> _future = Api.getItemRequests();
  final Set<String> _busy = {};

  void _reload() => setState(() => _future = Api.getItemRequests());

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _decide(ItemRequest r, bool approve) async {
    var note = '';
    if (!approve) {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject request'),
          content: TextField(
            controller: c,
            autofocus: true,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Why? The rep sees this', border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
          ],
        ),
      );
      note = c.text.trim();
      c.dispose();
      if (ok != true) return;
      if (note.isEmpty) return _snack('Say why it is rejected.');
    }
    setState(() => _busy.add(r.name));
    try {
      await Api.approveItemRequest(r.name, approve: approve, note: note);
      _snack(approve ? 'Approved: sent to the accountant.' : 'Rejected.');
      _reload();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(r.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Item Request Approvals')),
      body: FutureBuilder<List<ItemRequest>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final all = snap.data!;
          final waiting = all.where((r) => r.canApprove).toList();
          // The rest of the team's, decided or with the accountant, below - so
          // a manager can answer "where is my rep's request?" from here.
          final rest = all.where((r) => !r.canApprove).toList();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Text(waiting.isEmpty ? 'Nothing waiting for you.' : 'Waiting for you (${waiting.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              for (final r in waiting)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RequestCard(
                    r: r,
                    showRep: true,
                    actions: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy.contains(r.name) ? null : () => _decide(r, false),
                            child: const Text('Reject'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: _kOrange),
                            onPressed: _busy.contains(r.name) ? null : () => _decide(r, true),
                            child: const Text('Approve'),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              if (rest.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Earlier requests', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final r in rest)
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: _RequestCard(r: r, showRep: true)),
              ],
            ]),
          );
        },
      ),
    );
  }
}

/// A new item request.
class NewItemRequestScreen extends StatefulWidget {
  const NewItemRequestScreen({super.key});
  @override
  State<NewItemRequestScreen> createState() => _NewItemRequestScreenState();
}

/// Product line, type, pattern and size only (11 Nov 2026, the user): no
/// quantity, unit, customer, note or photo any more. The server still takes
/// those fields, so older requests that carry them keep showing them.
class _NewItemRequestScreenState extends State<NewItemRequestScreen> {
  String _line = kItemRequestLines.first;
  String _type = kItemRequestTypes.first;
  final _pattern = TextEditingController();
  final _size = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _pattern.dispose();
    _size.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_pattern.text.trim().isEmpty && _size.text.trim().isEmpty) {
      _snack('Enter a pattern or a size.');
      return;
    }
    setState(() => _busy = true);
    try {
      // Kept on the phone with no signal (11 Nov 2026).
      final sent = await Api.sendOrQueue(
        kind: 'item_request',
        label: 'Item request — $_line ${_pattern.text.trim()} ${_size.text.trim()}'.trim(),
        args: {
          'fields': {
            'product_line': _line,
            'item_type': _type,
            'pattern': _pattern.text.trim(),
            'size': _size.text.trim(),
          },
        },
      );
      if (!mounted) return;
      _snack(sent ? 'Request sent.' : kSavedOffline);
      Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Widget _drop(String label, String value, List<String> options, ValueChanged<String> onChanged) => DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        items: [for (final o in options) DropdownMenuItem(value: o, child: Text(o))],
        onChanged: _busy ? null : (v) => onChanged(v ?? value),
      );

  Widget _text(String label, TextEditingController c, {String? hint, TextInputType? type, int lines = 1}) => TextField(
        controller: c,
        enabled: !_busy,
        keyboardType: type,
        maxLines: lines,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: true),
      );

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(title: const Text('New Item Request')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _drop('Product line', _line, kItemRequestLines, (v) => setState(() => _line = v)),
        gap,
        _drop('Type', _type, kItemRequestTypes, (v) => setState(() => _type = v)),
        gap,
        _text('Pattern', _pattern, hint: 'e.g. VIKING'),
        gap,
        _text('Size', _size, hint: 'e.g. 205 x 129'),
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kOrange),
          onPressed: _busy ? null : _submit,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(_busy ? 'Sending…' : 'Send request')),
        ),
      ]),
    );
  }
}
