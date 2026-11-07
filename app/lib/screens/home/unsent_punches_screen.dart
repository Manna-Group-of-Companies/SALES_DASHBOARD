// Punches taken with no signal, waiting to be sent.
//
// They go by themselves when the signal returns, so a rep never has to come
// here. It exists for the two things they might want: to see that a punch is
// safely kept, and to deal with one the server would not take — which stays
// here, with the reason, until it is sent or they throw it away.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/pending_punches.dart';

class UnsentPunchesScreen extends StatefulWidget {
  const UnsentPunchesScreen({super.key});
  @override
  State<UnsentPunchesScreen> createState() => _UnsentPunchesScreenState();
}

class _UnsentPunchesScreenState extends State<UnsentPunchesScreen> {
  List<PendingPunch> _punches = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await PendingPunches.all();
    if (mounted) {
      setState(() {
        _punches = list;
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
        ? await PendingPunches.flush(Api.sendPendingPunch, describe: humanError)
        : const PunchFlushResult(0, [], true);
    if (!mounted) return;
    setState(() => _sending = false);
    await _load();
    if (!mounted) return;
    if (r.stoppedOffline && r.sent == 0) {
      _snack('Still no signal. They are safe here and will go by themselves.');
    } else if (r.failed.isNotEmpty) {
      _snack('Sent ${r.sent}; ${r.failed.length} could not be sent — '
          'the reason is on each one.');
    } else if (r.sent > 0) {
      _snack('Sent ${r.sent} punch${r.sent == 1 ? '' : 'es'} ✓');
    }
  }

  Future<void> _discard(PendingPunch p) async {
    final closes = _punches.where((o) => o.dependsOn == p.id).length;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this punch?'),
        content: Text('${_title(p)} at ${hhmm(p.at)} was never sent. This cannot be undone.'
            '${closes > 0 ? '\n\nIts punch-out goes too.' : ''}'),
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
    await PendingPunches.discard(p.id);
    await _load();
  }

  String _title(PendingPunch p) {
    final where = p.partyLabel ?? p.customer ?? p.lead ?? '';
    return switch (p.kind) {
      PunchKind.attendanceIn => 'Attendance punch-in',
      PunchKind.attendanceOut => 'Attendance punch-out',
      PunchKind.visitIn => 'Visit start${where.isEmpty ? '' : ' — $where'}',
      PunchKind.visitOut => 'Visit end${where.isEmpty ? '' : ' — $where'}',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unsent Punches')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _punches.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _banner(),
                      const SizedBox(height: 8),
                      for (final p in _punches) _card(p),
                    ],
                  ),
                ),
      bottomNavigationBar: _punches.isEmpty
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
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
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
            Text('Every punch has been sent',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('Punches made without signal wait here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
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
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 20, color: Color(0xFFB35309)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Not sent yet. They send by themselves when you have signal.',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ),
        ]),
      );

  Widget _card(PendingPunch p) {
    final waiting = p.dependsOn != null;
    final day = p.date == today() ? 'today' : p.date;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(p.isIn ? Icons.login : Icons.logout,
                size: 20, color: const Color(0xFFF46A21)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_title(p),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            '${hhmm(p.at)} $day  ·  '
            '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}'
            '${p.accuracy != null && p.accuracy! > 0 ? '  ·  ±${p.accuracy!.round()} m' : ''}',
            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
          ),
          if (waiting) ...[
            const SizedBox(height: 6),
            const Text('Goes after the punch-in it closes.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
          if (p.lastError != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('Last try: ${p.lastError}',
                  style: const TextStyle(fontSize: 12, height: 1.35)),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _sending ? null : () => _discard(p),
              child: const Text('Discard',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ),
        ]),
      ),
    );
  }
}
