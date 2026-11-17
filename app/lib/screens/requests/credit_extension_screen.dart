// Temporary credit extensions on the phone (16 Nov 2026). A separate workflow
// from order approval: a rep asks on an over-limit order; the manager reviews
// and approves an extra amount (pushing it to SAP) or sends it to the GM; a
// missed payment commitment comes to the GM by itself. See
// core/credit_extension.dart.
//
// 17 Nov 2026: the notifications the Server Script raises are shown at the
// top of the list (they went to Frappe's Notification Log, which nothing
// read); a manager sees their authority and the cap; an extension the morning
// watchdog escalated before SAP's payments were counted says so. The GM sets
// the authority and the cap on the dashboard, not here.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit_extension.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/outbox.dart';
import 'package:manna_field_sales/screens/requests/payment_commitments_screen.dart';

const Color _kOrange = Color(0xFFF46A21);
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  return m == null ? '' : '${m[3]} ${_months[int.parse(m[2]!) - 1]} ${m[1]}';
}

String _rs(num v) => 'Rs ${v.round()}';
String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Color _color(String status) => switch (status) {
      kXtPaid => const Color(0xFF2E7D32),
      kXtRejected || kXtRejectedByGm || kXtOverdue || kXtPushFailed => Colors.red.shade700,
      kXtActive || kXtSending => const Color(0xFF1565C0),
      kXtPendingGm || kXtRenewed => const Color(0xFF6A1B9A),
      _ => const Color(0xFFB26A00),
    };

Widget _badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );

/// Every extension this login may see; what waits on it first.
class CreditExtensionsScreen extends StatefulWidget {
  const CreditExtensionsScreen({super.key});
  @override
  State<CreditExtensionsScreen> createState() => _CreditExtensionsScreenState();
}

class _CreditExtensionsScreenState extends State<CreditExtensionsScreen> {
  late Future<List<CreditExtension>> _future = Api.getCreditExtensions();
  List<Map<String, dynamic>> _alerts = const [];

  @override
  void initState() {
    super.initState();
    _loadAlerts();
  }

  // An alert that fails to load must not hide the requests.
  Future<void> _loadAlerts() async {
    try {
      final a = await Api.getExtensionAlerts();
      if (mounted) setState(() => _alerts = a);
    } catch (_) {}
  }

  void _reload() {
    setState(() => _future = Api.getCreditExtensions());
    _loadAlerts();
  }

  Future<void> _seen() async {
    await Api.markExtensionAlertsSeen();
    _loadAlerts();
  }

  Future<void> _authority() async {
    try {
      final s = await Api.getExtensionSettings();
      if (!mounted) return;
      final mine = s['my_authority'];
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Approval authority'),
          content: Text([
            if (mine is num) 'Your authority: ${_rs(mine)} per extension.',
            'A manager may give a commitment of at most ${s['max_days'] ?? kExtensionManagerMaxDays} days, and at most '
                '${s['manager_cap_count']} extension(s) for one customer in ${s['manager_cap_days']} days. '
                'Anything past that goes to the GM.',
            if (s['can_edit'] == 1) 'You set these on the web dashboard, under Temporary Credit.',
          ].join('\n\n')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(humanError(e))));
    }
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
            TextButton(onPressed: _seen, child: const Text('Mark read')),
          ]),
          for (final a in unread.take(10))
            InkWell(
              onTap: '${a['extension'] ?? ''}'.isEmpty ? null : () => _open(CreditExtensionDetailScreen(name: '${a['extension']}')),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('${_date('${a['at']}')}  ·  ${a['subject']}', style: const TextStyle(fontSize: 13)),
              ),
            ),
        ]),
      ),
    );
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) _reload();
  }

  Widget _card(CreditExtension x) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFE5E7EB))),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _open(CreditExtensionDetailScreen(name: x.name)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(x.customerName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                _badge(x.status, _color(x.status)),
              ]),
              const SizedBox(height: 4),
              Text(
                x.amount > 0
                    ? '${_rs(x.amount)} until ${_date(x.commitmentDate)}  ·  ${x.paymentStatus}'
                    : 'Order ${x.salesOrder}  ·  over the limit by ${_rs(x.excess)}',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text([x.name, if (x.salesPerson.isNotEmpty) x.salesPerson, _date(x.requestedOn)].join('  ·  '),
                  style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
              if (x.overdueUnchecked)
                const Text('Payment not yet checked in SAP', style: TextStyle(fontSize: 12.5, color: Colors.black54)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final canAsk = Session.I.salesPerson != null || Session.I.isManager || Session.I.isGM;
    return Scaffold(
      appBar: AppBar(title: const Text('Temporary Credit'), actions: [
        if (Session.I.isManager || Session.I.isGM)
          IconButton(tooltip: 'Approval authority', icon: const Icon(Icons.info_outline), onPressed: _authority),
      ]),
      floatingActionButton: canAsk
          ? FloatingActionButton.extended(
              backgroundColor: _kOrange,
              foregroundColor: Colors.white,
              onPressed: () => _open(const NewCreditExtensionScreen()),
              icon: const Icon(Icons.add),
              label: const Text('New request'),
            )
          : null,
      body: FutureBuilder<List<CreditExtension>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final all = snap.data!;
          final waiting = all.where((x) => x.waitingOnMe).toList();
          final rest = all.where((x) => !x.waitingOnMe).toList();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
              _alertsCard(),
              if (all.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No temporary credit requests.', textAlign: TextAlign.center)),
              if (waiting.isNotEmpty) ...[
                Text('Waiting for you (${waiting.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final x in waiting) Padding(padding: const EdgeInsets.only(bottom: 8), child: _card(x)),
                const SizedBox(height: 8),
              ],
              if (rest.isNotEmpty && waiting.isNotEmpty)
                const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Other requests', style: TextStyle(fontWeight: FontWeight.bold))),
              for (final x in rest) Padding(padding: const EdgeInsets.only(bottom: 8), child: _card(x)),
            ]),
          );
        },
      ),
    );
  }
}

/// A new request: one of this login's orders that takes its customer past the limit.
class NewCreditExtensionScreen extends StatefulWidget {
  const NewCreditExtensionScreen({super.key});
  @override
  State<NewCreditExtensionScreen> createState() => _NewCreditExtensionScreenState();
}

class _NewCreditExtensionScreenState extends State<NewCreditExtensionScreen> {
  late final Future<List<EligibleOrder>> _future = Api.getExtensionEligibleOrders();
  bool _busy = false;

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _ask(EligibleOrder o) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Temporary credit for ${o.customerName}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Over the limit by ${_rs(o.excess)} with order ${o.salesOrder}.'),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'What has the customer promised?', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    final note = c.text.trim();
    c.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final sent = await Api.requestCreditExtension(o.salesOrder, o.customerName, note);
      _snack(sent ? 'Sent.' : kSavedOffline);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Temporary Credit')),
      body: FutureBuilder<List<EligibleOrder>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No waiting order takes its customer past the credit limit.', textAlign: TextAlign.center)));
          }
          return ListView(padding: const EdgeInsets.all(12), children: [
            for (final o in rows)
              Card(
                child: ListTile(
                  enabled: !_busy && !o.hasRequest,
                  title: Text(o.customerName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${o.salesOrder} · order ${_rs(o.orderAmount)}\nLimit ${_rs(o.creditLimit)} · owes ${_rs(o.outstanding)} · over by ${_rs(o.excess)}'
                      '${o.hasRequest ? '\nAlready requested' : ''}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _ask(o),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// The review: the customer's credit, the order, payments, earlier
/// extensions and missed commitments, and the decision this login may make.
class CreditExtensionDetailScreen extends StatefulWidget {
  final String name;
  const CreditExtensionDetailScreen({super.key, required this.name});
  @override
  State<CreditExtensionDetailScreen> createState() => _CreditExtensionDetailScreenState();
}

class _CreditExtensionDetailScreenState extends State<CreditExtensionDetailScreen> {
  late Future<Map<String, dynamic>> _future = Api.getCreditExtensionDetail(widget.name);
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  final _remarks = TextEditingController();
  DateTime? _commit;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    _remarks.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _act(CreditExtension x, String action, double authority) async {
    final today = _iso(DateTime.now());
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', '')) ?? 0;
    final date = _commit == null ? '' : _iso(_commit!);
    if (action == 'approve') {
      final problem = x.actor == 'gm'
          ? xtCheckGm(amount: amount, today: today, commitment: date, remarks: _remarks.text)
          : xtCheckManager(
              amount: amount, authority: authority, approvedOn: today, commitment: date,
              reason: _reason.text, remarks: _remarks.text);
      if (problem != null) return _snack(kXtMessages[problem]!);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Approve and push to SAP?'),
          content: Text('${x.customerName}\'s credit limit in SAP goes up by ${_rs(amount)} until ${_date(date)}, '
              'then back to what it was.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve & Push to SAP')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (action == 'reject' && _remarks.text.trim().isEmpty) return _snack('Enter the rejection remarks.');
    setState(() => _busy = true);
    try {
      final sent = await Api.creditExtensionAction(x.name, action,
          amount: action == 'approve' ? amount : null,
          commitmentDate: action == 'approve' ? date : null,
          reason: _reason.text.trim(),
          remarks: _remarks.text.trim(),
          customerName: x.customerName);
      _snack(sent ? 'Done.' : kSavedOffline);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String k, String v) => v.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 150, child: Text(k, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(v)),
          ]),
        );

  Widget _section(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(humanError(snap.error), textAlign: TextAlign.center)));
          }
          final d = snap.data!;
          final x = CreditExtension(d['extension'] as Map);
          final c = (d['customer'] as Map? ?? {}).cast<String, dynamic>();
          final h = (d['history'] as Map? ?? {}).cast<String, dynamic>();
          final authority = (d['manager_authority'] as num?)?.toDouble() ?? 0;
          final cap = (d['manager_cap'] as Map? ?? {}).cast<String, dynamic>();
          final capUsed = (cap['used'] as num?)?.toInt() ?? 0;
          final capCount = (cap['count'] as num?)?.toInt() ?? kExtensionManagerCapCount;
          final capDays = (cap['days'] as num?)?.toInt() ?? kExtensionManagerCapDays;
          final deciding = x.canApprove || x.canReject || x.canEscalate;
          if (_reason.text.isEmpty && x.requestReason.isNotEmpty && !x.requestReason.startsWith('Renewal of')) {
            _reason.text = x.requestReason;
          }
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = Api.getCreditExtensionDetail(widget.name)),
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Row(children: [
                Expanded(child: Text(x.customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                _badge(x.status, _color(x.status)),
              ]),
              const SizedBox(height: 8),
              if (x.overdueUnchecked)
                const Card(
                  color: Color(0xFFFFF4E5),
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Escalated by the morning check because the payment date passed before SAP\'s payments were '
                        'counted. The next SAP check will say whether the customer paid in time.'),
                  ),
                ),
              _section('Customer', [
                _row('Customer', '${x.customerName} (${x.bpCode})'),
                _row('SAP credit limit', _rs((c['credit_limit'] as num?) ?? x.creditLimit)),
                _row('Outstanding', _rs((c['outstanding'] as num?) ?? x.outstanding)),
                _row('Overdue', _rs((c['overdue'] as num?) ?? x.overdue)),
                _row('Order', '${x.salesOrder} · ${_rs(x.orderAmount)}'),
                _row('Excess credit', _rs(x.excess)),
                _row('Rep', x.salesPerson),
                _row('Rep\'s note', x.requestReason),
                _row('Escalated', x.escalationReason),
              ]),
              if (x.amount > 0)
                _section('Extension', [
                  _row('Additional credit', _rs(x.amount)),
                  _row('Commitment date', _date(x.commitmentDate)),
                  _row('Approved', '${_date(x.approvedOn)} · ${x.approverRole == 'gm' ? 'GM' : 'Manager'}'),
                  _row('Reason', x.reason),
                  _row('Remarks', x.remarks),
                  _row('Paid (SAP)', '${_rs(x.paid)} · ${x.paymentStatus}'),
                  _row('Remaining', _rs(x.remaining)),
                  _row('SAP', x.sapReference),
                  _row('SAP error', x.sapError),
                  _row('Restore', x.restoreStatus),
                ]),
              if (x.rejectionRemarks.isNotEmpty) _section('Rejected', [Text(x.rejectionRemarks)]),
              _section('This customer\'s extensions', [
                _row('Extensions', '${h['total_extensions'] ?? 0}'),
                _row('Missed commitments', '${h['missed_commitments'] ?? 0}'),
                _row('GM escalations', '${h['gm_escalations'] ?? 0}'),
                _row('Approved credit', _rs((h['total_additional_credit'] as num?) ?? 0)),
                _row('Paid against them', _rs((h['total_paid_against_commitments'] as num?) ?? 0)),
                _row('Manager extensions', '$capUsed of $capCount in the last $capDays days'),
                for (final e in ((h['extensions'] as List?) ?? const []).cast<Map>())
                  if ('${e['name']}' != x.name)
                    _row('${e['name']}', '${e['status']} · ${_rs((e['amount'] as num?) ?? 0)}${e['missed'] == 1 ? ' · missed' : ''}'),
              ]),
              if (((d['payments'] as List?) ?? const []).isNotEmpty)
                _section('SAP payments counted', [
                  for (final p in (d['payments'] as List).cast<Map>()) _row(_date('${p['date']}'), '${_rs((p['amount'] as num?) ?? 0)} · no. ${p['doc_num']}'),
                ]),
              if (((d['invoices'] as List?) ?? const []).isNotEmpty)
                _section('Recent invoices', [
                  for (final i in (d['invoices'] as List).cast<Map>().take(8))
                    _row(_date('${i['posting_date']}'), '${i['invoice_no']} · ${_rs((i['total'] as num?) ?? 0)} · paid ${_rs((i['paid'] as num?) ?? 0)}'),
                ]),
              _section('History', [
                for (final l in ((d['log'] as List?) ?? const []).cast<Map>())
                  _row(_date('${l['at']}'), '${l['action']} · ${l['role']}${'${l['remarks'] ?? ''}'.isNotEmpty ? ' · ${l['remarks']}' : ''}'),
              ]),
              if (deciding) ...[
                const SizedBox(height: 8),
                if (x.actor == 'manager' && x.canApprove && capUsed >= capCount)
                  Text('This customer has had $capUsed manager extension(s) in $capDays days, the most a manager may give. '
                      'Send it to the GM.',
                      style: TextStyle(color: Colors.red.shade700)),
                if (x.canApprove) ...[
                  TextField(
                    controller: _amount,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: 'Temporary additional credit (Rs)',
                        helperText: x.actor == 'manager' ? 'Your authority: ${_rs(authority)}' : null,
                        border: const OutlineInputBorder(),
                        isDense: true),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            final now = DateTime.now();
                            final first = DateTime(now.year, now.month, now.day);
                            final p = await showDatePicker(
                                context: context,
                                firstDate: first,
                                lastDate: x.actor == 'gm' ? first.add(const Duration(days: 365)) : first.add(const Duration(days: kExtensionManagerMaxDays)),
                                initialDate: _commit ?? first);
                            if (p != null) setState(() => _commit = p);
                          },
                    icon: const Icon(Icons.event),
                    label: Text(_commit == null ? 'Payment commitment date' : 'Commitment: ${_date(_iso(_commit!))}'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                      controller: _reason,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: 'Reason for extension', border: OutlineInputBorder(), isDense: true)),
                  const SizedBox(height: 10),
                ],
                TextField(
                    controller: _remarks,
                    enabled: !_busy,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Remarks (required)', border: OutlineInputBorder(), isDense: true)),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 8, children: [
                  if (x.canReject) OutlinedButton(onPressed: _busy ? null : () => _act(x, 'reject', authority), child: const Text('Reject')),
                  if (x.canEscalate)
                    OutlinedButton(onPressed: _busy ? null : () => _act(x, 'escalate', authority), child: const Text('Send to GM')),
                  if (x.canApprove)
                    FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _kOrange),
                        onPressed: _busy ? null : () => _act(x, 'approve', authority),
                        child: const Text('Approve & Push to SAP')),
                ]),
              ],
              if (x.canRetry)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _kOrange),
                      onPressed: _busy ? null : () => _act(x, 'retry', authority),
                      child: const Text('Push to SAP again')),
                ),
            ]),
          );
        },
      ),
    );
  }
}

/// On an order's page: its 10-day payment commitment, if it has one (17 Nov
/// 2026), so whoever reads the order sees the promised date and whether it
/// was kept. Nothing when there is none, or this login may not see it.
/// (Named for the temporary credit extension it replaced; the two merged.)
class TemporaryCreditStrip extends StatefulWidget {
  final String orderName;
  const TemporaryCreditStrip({super.key, required this.orderName});
  @override
  State<TemporaryCreditStrip> createState() => _TemporaryCreditStripState();
}

class _TemporaryCreditStripState extends State<TemporaryCreditStrip> {
  Map? _c;

  @override
  void initState() {
    super.initState();
    Api.getOrderRoute(widget.orderName).then((r) {
      if (mounted) setState(() => _c = r['commitment'] as Map?);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final st = '${c?['status'] ?? ''}';
    if (c == null || st == 'Pending' || st == 'Cancelled' || st.isEmpty) return const SizedBox.shrink();
    final color = st == 'Kept'
        ? const Color(0xFF2E7D32)
        : st == 'Missed'
            ? Colors.red.shade700
            : const Color(0xFFB26A00);
    final what = switch (st) {
      'Kept' => 'kept',
      'Missed' => 'missed',
      'Unchecked' => 'payment pending, not yet checked in SAP',
      _ => 'payment pending',
    };
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentCommitmentsScreen())),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(Icons.add_card, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Payment commitment to ${_date('${c['commitment_date'] ?? ''}')}: $what\n'
              'Given by the ${'${c['approver_role']}' == 'gm' ? 'GM' : 'Manager'}',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ]),
      ),
    );
  }
}
