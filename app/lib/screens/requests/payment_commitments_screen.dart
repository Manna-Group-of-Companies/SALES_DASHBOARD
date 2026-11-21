// Payment commitments on the phone (17 Nov 2026): every 10-day payment
// commitment given on an order, by the Manager or the GM, and what became of
// it - the customer-wise history the user asked for, with this login's alerts
// on top. Commitments are given on the order itself (the manager's review, the
// GM's approval); this is where they are followed. It replaces the temporary
// credit extension screens: the two merged on the user's choice. See
// core/payment_commitment.dart.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/payment_commitment.dart';
import 'package:manna_field_sales/services/api.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch('${v ?? ''}');
  return m == null ? '' : '${m[3]} ${_months[int.parse(m[2]!) - 1]} ${m[1]}';
}

String _rs(Object? v) => 'Rs ${((v is num) ? v : num.tryParse('$v') ?? 0).round()}';

String _s(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

(String, Color) _status(Map r) {
  final st = _s(r['status']);
  if (st == kPcKept) return ('Kept', const Color(0xFF2E7D32));
  if (st == kPcMissed) return (_s(r['cleared_on']).isEmpty ? 'Missed' : 'Missed · cleared', Colors.red.shade700);
  if (st == kPcCancelled) return ('Cancelled', Colors.black45);
  if (st == kPcUnchecked) return ('Payment pending · not yet checked', const Color(0xFFB26A00));
  return ('Payment pending', const Color(0xFFB26A00));
}

Widget _badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );

class PaymentCommitmentsScreen extends StatefulWidget {
  const PaymentCommitmentsScreen({super.key});
  @override
  State<PaymentCommitmentsScreen> createState() => _PaymentCommitmentsScreenState();
}

class _PaymentCommitmentsScreenState extends State<PaymentCommitmentsScreen> {
  late Future<List<Map<String, dynamic>>> _future = Api.getPaymentCommitments();
  List<Map<String, dynamic>> _alerts = const [];
  bool _openOnly = true;

  @override
  void initState() {
    super.initState();
    _loadAlerts();
  }

  // An alert that fails to load must not hide the commitments.
  Future<void> _loadAlerts() async {
    try {
      final a = await Api.getLadderAlerts();
      if (mounted) setState(() => _alerts = a);
    } catch (_) {}
  }

  void _reload() {
    setState(() => _future = Api.getPaymentCommitments());
    _loadAlerts();
  }

  Widget _alertsCard() {
    final unread = _alerts.where((a) => a['read'] != 1).toList();
    if (unread.isEmpty) return const SizedBox.shrink();
    return Card(
      color: const Color(0xFFFFF4E5),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Alerts (${unread.length})', style: const TextStyle(fontWeight: FontWeight.bold))),
            TextButton(
                onPressed: () async {
                  await Api.markLadderAlertsSeen();
                  _loadAlerts();
                },
                child: const Text('Mark read')),
          ]),
          for (final a in unread.take(10))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${_date(a['at'])}  ·  ${a['subject']}', style: const TextStyle(fontSize: 13)),
            ),
        ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final (label, color) = _status(r);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFE5E7EB))),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => CommitmentHistoryScreen(customer: _s(r['customer']), name: _s(r['customer_name'])))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(_s(r['customer_name']).isEmpty ? _s(r['customer']) : _s(r['customer_name']),
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
              _badge(label, color),
            ]),
            const SizedBox(height: 4),
            Text('Pays by ${_date(r['commitment_date'])}  ·  ${r['days']} days  ·  ${_s(r['approver_role']) == 'gm' ? 'GM' : 'Manager'}',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
                [
                  _s(r['sales_order']),
                  _rs(r['order_amount']),
                  'given ${_date(r['approved_on'])}',
                  'owed ${_rs(r['outstanding_at'])}, overdue ${_rs(r['overdue_at'])}',
                ].join('  ·  '),
                style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Commitments')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final all = snap.data!;
          final open = all.where((r) => r['status'] == kPcRunning || r['status'] == kPcUnchecked).toList();
          final shown = _openOnly ? open : all;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(padding: const EdgeInsets.all(12), children: [
              _alertsCard(),
              Row(children: [
                ChoiceChip(
                    label: Text('Payment pending (${open.length})'),
                    selected: _openOnly,
                    onSelected: (_) => setState(() => _openOnly = true)),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: Text('All (${all.length})'),
                    selected: !_openOnly,
                    onSelected: (_) => setState(() => _openOnly = false)),
              ]),
              const SizedBox(height: 8),
              if (shown.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No payment commitments.', textAlign: TextAlign.center)),
              for (final r in shown) Padding(padding: const EdgeInsets.only(bottom: 8), child: _card(r)),
            ]),
          );
        },
      ),
    );
  }
}

/// One customer's whole commitment history: the counts, then every commitment.
class CommitmentHistoryScreen extends StatelessWidget {
  final String customer;
  final String name;
  const CommitmentHistoryScreen({super.key, required this.customer, this.name = ''});

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: const TextStyle(color: Colors.black54))),
          Expanded(child: Text(v)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name.isEmpty ? customer : name)),
      body: FutureBuilder<Map<String, dynamic>>(
        future: Api.getCommitmentHistory(customer),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final h = snap.data!;
          final rows = ((h['rows'] as List?) ?? const []).cast<Map>();
          return ListView(padding: const EdgeInsets.all(12), children: [
            if (h['gm_lock'] == true)
              Card(
                color: Colors.red.shade50,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Orders go to the GM: a missed commitment is not cleared yet.'),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _row('Commitments given', '${h['commitments_given']} (${h['by_manager']} Manager, ${h['by_gm']} GM)'),
                  _row('Total days given', '${h['total_days']}'),
                  _row('Kept / missed / pending', '${h['kept']} / ${h['missed']} / ${h['running']}'),
                  _row('Outstanding now', _rs(h['outstanding_now'])),
                  if (((h['overdue_now'] as num?) ?? 0) > 1)
                    _row('Overdue now', '${_rs(h['overdue_now'])}, oldest ${h['overdue_days_now']} days late'),
                ]),
              ),
            ),
            for (final r in rows)
              Card(
                elevation: 0,
                child: ListTile(
                  title: Text('${_s(r['sales_order'])} · ${_rs(r['order_amount'])}'),
                  subtitle: Text([
                    '${_s(r['approver_role']) == 'gm' ? 'GM' : 'Manager'} (${_s(r['approved_by'])}) on ${_date(r['approved_on'])}',
                    '${r['days']} days, pays by ${_date(r['commitment_date'])}',
                    'Owed ${_rs(r['outstanding_at'])}, overdue ${_rs(r['overdue_at'])} (${r['overdue_days_at']} days)',
                    if (_s(r['remarks']).isNotEmpty) '"${_s(r['remarks'])}"',
                  ].join('\n')),
                  isThreeLine: true,
                  trailing: Builder(builder: (_) {
                    final (label, color) = _status(r);
                    return _badge(label, color);
                  }),
                ),
              ),
          ]);
        },
      ),
    );
  }
}
