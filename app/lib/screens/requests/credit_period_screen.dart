// Credit-period requests on the phone (16 Nov 2026). A rep asks from the
// customer's screen; the rep's manager decides up to 30 days and pushes it to
// SAP, and escalates 31 to 40 days to the GM, who decides and pushes those.
// One list serves all three: what is waiting on this login first, with its
// buttons, then everything else it may see. See core/credit_period_request.dart.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit_period_request.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/outbox.dart';

const Color _kOrange = Color(0xFFF46A21);
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  return m == null ? '' : '${m[3]} ${_months[int.parse(m[2]!) - 1]}';
}

Color _statusColor(String status) => switch (status) {
      kCprInSap => const Color(0xFF2E7D32),
      kCprRejected => Colors.red.shade700,
      kCprApproved || kCprSending => const Color(0xFF1565C0),
      kCprWithGm => const Color(0xFF6A1B9A),
      _ => const Color(0xFFB26A00),
    };

class CreditPeriodCard extends StatelessWidget {
  final CreditPeriodRequest r;
  final bool showRep;
  final Widget? actions;
  const CreditPeriodCard({super.key, required this.r, this.showRep = false, this.actions});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(r.status);
    final from = r.currentTerm.isEmpty ? 'no term' : r.currentTerm;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFE5E7EB))),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.customerName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
              child: Text(r.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('$from  →  ${r.requestedTerm} (${r.requestedDays} days)',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            [
              if (showRep && r.salesPerson.isNotEmpty) r.salesPerson,
              r.needsGm ? 'GM decides' : 'Manager decides',
              _date(r.requestedOn),
            ].where((s) => s.isNotEmpty).join('  ·  '),
            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
          ),
          if (r.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r.reason, style: const TextStyle(fontSize: 13)),
          ],
          if (r.managerNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Manager: ${r.managerNote}', style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ],
          if (r.decisionNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('${r.approverRole == 'gm' ? 'GM' : 'Manager'}: ${r.decisionNote}',
                style: TextStyle(fontSize: 13, color: r.status == kCprRejected ? Colors.red.shade700 : Colors.black87)),
          ],
          if (r.sapError.isNotEmpty && r.status == kCprApproved) ...[
            const SizedBox(height: 4),
            Text('SAP: ${r.sapError}', style: TextStyle(fontSize: 13, color: Colors.red.shade700)),
          ],
          if (r.status == kCprSending) ...[
            const SizedBox(height: 4),
            const Text('Waiting for the SAP sync. This changes by itself.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54)),
          ],
          ?actions,
        ]),
      ),
    );
  }
}

/// Every credit-period request this login may see: a rep's own, a manager's
/// team's, all of them for the GM. The server says which buttons apply.
class CreditPeriodRequestsScreen extends StatefulWidget {
  const CreditPeriodRequestsScreen({super.key});
  @override
  State<CreditPeriodRequestsScreen> createState() => _CreditPeriodRequestsScreenState();
}

class _CreditPeriodRequestsScreenState extends State<CreditPeriodRequestsScreen> {
  late Future<List<CreditPeriodRequest>> _future = Api.getCreditPeriodRequests();
  final Set<String> _busy = {};

  void _reload() => setState(() => _future = Api.getCreditPeriodRequests());

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<String?> _ask(String title, String label, {required bool required, required String button}) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 2,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(button)),
        ],
      ),
    );
    final note = c.text.trim();
    c.dispose();
    if (ok != true) return null;
    if (required && note.isEmpty) {
      _snack('Say why it is rejected.');
      return null;
    }
    return note;
  }

  Future<void> _act(CreditPeriodRequest r, String action) async {
    var note = '';
    if (action == 'reject') {
      final n = await _ask('Reject request', 'Why? The rep sees this', required: true, button: 'Reject');
      if (n == null) return;
      note = n;
    } else if (action == 'escalate') {
      final n = await _ask('Send to the GM', 'Note for the GM (optional)', required: false, button: 'Send to GM');
      if (n == null) return;
      note = n;
    } else if (action == 'push') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Push to SAP?'),
          content: Text('${r.customerName}\'s payment term in SAP (Manna Treads) becomes '
              '${r.requestedTerm} (${r.requestedDays} days). The credit limit is not changed.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Push to SAP')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy.add(r.name));
    try {
      final sent = await Api.creditPeriodAction(r.name, action, note: note, customerName: r.customerName);
      _snack(!sent
          ? kSavedOffline
          : switch (action) {
              'approve' => 'Approved. Push it to SAP when ready.',
              'reject' => 'Rejected.',
              'escalate' => 'Sent to the GM.',
              _ => 'Sent to SAP. The status changes once SAP has it.',
            });
      _reload();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(r.name));
    }
  }

  Widget _buttons(CreditPeriodRequest r) {
    final busy = _busy.contains(r.name);
    Widget b(String label, String action, {bool primary = false}) => Expanded(
          child: primary
              ? FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _kOrange),
                  onPressed: busy ? null : () => _act(r, action),
                  child: Text(label))
              : OutlinedButton(onPressed: busy ? null : () => _act(r, action), child: Text(label)),
        );
    final row = <Widget>[
      if (r.canReject) b('Reject', 'reject'),
      if (r.canEscalate) b('Send to GM', 'escalate', primary: true),
      if (r.canApprove) b('Approve', 'approve', primary: true),
      if (r.canPush) b('Push to SAP', 'push', primary: true),
    ];
    final spaced = <Widget>[];
    for (final w in row) {
      if (spaced.isNotEmpty) spaced.add(const SizedBox(width: 10));
      spaced.add(w);
    }
    return Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: spaced));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Credit Period Requests')),
      body: FutureBuilder<List<CreditPeriodRequest>>(
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
          final waiting = all.where((r) => r.waitingOnMe).toList();
          final rest = all.where((r) => !r.waitingOnMe).toList();
          final deciding = all.any((r) => r.actor == 'manager' || r.actor == 'gm');
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(padding: const EdgeInsets.all(12), children: [
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No credit-period requests yet. A rep asks from the customer\'s screen.',
                      textAlign: TextAlign.center),
                ),
              if (waiting.isNotEmpty || deciding) ...[
                Text(waiting.isEmpty ? 'Nothing waiting for you.' : 'Waiting for you (${waiting.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final r in waiting)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CreditPeriodCard(r: r, showRep: true, actions: _buttons(r)),
                  ),
              ],
              if (rest.isNotEmpty) ...[
                const SizedBox(height: 12),
                if (waiting.isNotEmpty || deciding)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Other requests', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                for (final r in rest)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CreditPeriodCard(r: r, showRep: r.actor != 'rep'),
                  ),
              ],
            ]),
          );
        },
      ),
    );
  }
}

/// A rep's new request for [customer] (a Customer map: name, customer_name,
/// custom_payment_terms). Offers SAP's own terms of 40 days or fewer.
class NewCreditPeriodRequestScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  const NewCreditPeriodRequestScreen({super.key, required this.customer});
  @override
  State<NewCreditPeriodRequestScreen> createState() => _NewCreditPeriodRequestScreenState();
}

class _NewCreditPeriodRequestScreenState extends State<NewCreditPeriodRequestScreen> {
  late final Future<List<SapPaymentTerm>> _terms = Api.getSapPaymentTerms();
  final _reason = TextEditingController();
  SapPaymentTerm? _pick;
  bool _busy = false;

  String get _current {
    final s = '${widget.customer['custom_payment_terms'] ?? ''}'.trim();
    return s == 'null' ? '' : s;
  }

  String get _customerName => '${widget.customer['customer_name'] ?? widget.customer['name']}';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _submit() async {
    final t = _pick;
    if (t == null) return _snack('Choose the credit period.');
    setState(() => _busy = true);
    try {
      final sent = await Api.submitCreditPeriodRequest(
        customer: '${widget.customer['name']}',
        customerName: _customerName,
        term: t,
        reason: _reason.text.trim(),
      );
      if (!mounted) return;
      _snack(sent
          ? (cprBand(t.days) == 'gm' ? 'Sent. Your manager will pass it to the GM.' : 'Sent to your manager.')
          : kSavedOffline);
      Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Request Credit Period')),
      body: FutureBuilder<List<SapPaymentTerm>>(
        future: _terms,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final all = snap.data!;
          int? currentCode;
          for (final t in all) {
            if (_current.isNotEmpty && t.name == _current) currentCode = t.code;
          }
          final offered = cprOfferedTerms(all, currentCode);
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(_customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Now: ${_current.isEmpty ? 'no payment term in SAP' : _current}',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            if (offered.isEmpty)
              const Text('SAP\'s payment terms have not reached the app yet. Press Sync and try again.')
            else
              RadioGroup<int>(
                groupValue: _pick?.code,
                onChanged: (v) {
                  if (_busy) return;
                  setState(() => _pick = offered.firstWhere((t) => t.code == v));
                },
                child: Column(children: [
                  for (final t in offered)
                    RadioListTile<int>(
                      value: t.code,
                      title: Text(t.label),
                      subtitle: Text(cprBand(t.days) == 'gm' ? 'Manager, then the GM' : 'Your manager decides'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ]),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              enabled: !_busy,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Why does the customer need it?', border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 8),
            const Text('Over 40 days cannot be asked for here.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kOrange),
              onPressed: _busy || offered.isEmpty ? null : _submit,
              child: Padding(padding: const EdgeInsets.all(12), child: Text(_busy ? 'Sending…' : 'Send request')),
            ),
          ]);
        },
      ),
    );
  }
}

/// On the customer's screen: their payment term, the latest request for it,
/// and - for a rep, on a customer with a SAP code - the way to ask.
class CreditPeriodCustomerSection extends StatefulWidget {
  final Map<String, dynamic> customer;
  final bool canAsk;
  const CreditPeriodCustomerSection({super.key, required this.customer, required this.canAsk});
  @override
  State<CreditPeriodCustomerSection> createState() => _CreditPeriodCustomerSectionState();
}

class _CreditPeriodCustomerSectionState extends State<CreditPeriodCustomerSection> {
  late Future<List<CreditPeriodRequest>> _future = _load();

  Future<List<CreditPeriodRequest>> _load() =>
      Api.getCreditPeriodRequests(customer: '${widget.customer['name']}');

  String _s(String k) {
    final v = '${widget.customer[k] ?? ''}'.trim();
    return v == 'null' ? '' : v;
  }

  @override
  Widget build(BuildContext context) {
    final hasCode = _s('custom_bp_code').isNotEmpty;
    final terms = _s('custom_payment_terms');
    return FutureBuilder<List<CreditPeriodRequest>>(
      future: _future,
      builder: (context, snap) {
        final rows = snap.data ?? const <CreditPeriodRequest>[];
        final open = rows.where((r) => [kCprWithManager, kCprWithGm, kCprApproved, kCprSending].contains(r.status)).toList();
        final latest = rows.isEmpty ? null : rows.first;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.event_repeat, size: 18, color: Colors.black54),
            const SizedBox(width: 6),
            Expanded(child: Text('Payment terms: ${terms.isEmpty ? '—' : terms}')),
          ]),
          if (latest != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: CreditPeriodCard(r: latest),
            ),
          if (widget.canAsk && hasCode && open.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton.icon(
                onPressed: () async {
                  final done = await Navigator.push<bool>(context,
                      MaterialPageRoute(builder: (_) => NewCreditPeriodRequestScreen(customer: widget.customer)));
                  if (done == true && mounted) setState(() => _future = _load());
                },
                icon: const Icon(Icons.event_repeat),
                label: const Padding(padding: EdgeInsets.all(10), child: Text('Request Credit Period')),
              ),
            ),
        ]);
      },
    );
  }
}
