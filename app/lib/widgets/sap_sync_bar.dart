// How fresh the credit figures are, and — for those allowed — a way to refresh.
//
// WHY IT SITS WITH THE CREDIT FIGURES
//
// The limit and the outstanding above it come from SAP on a nightly job. A
// limit raised this morning is not visible until tomorrow, and a rep standing
// in the shop has no way of knowing whether the number they are being refused
// by is today's. Saying when it was last synced answers that; the button acts
// on the answer.
//
// WHO SEES THE BUTTON
//
// Only a manager. `manna_sap_request_sync` admits Accounts Manager, Sales
// Manager and System Manager and throws for anybody else, so offering it to a
// rep would be offering a button that always fails. The freshness line is
// shown to everyone, because it is useful to everyone.
//
// THE COOLDOWN IS NOT A UI PREFERENCE
//
// The SAP Service Layer licence pool is tiny. Logging in inside the window
// returns HTTP 500 for 20-30 minutes and takes the integration down for
// everyone. The refusal therefore lives in the Server Script, where nothing on
// a phone can reach it. Disabling the button here is a courtesy, not the
// control — and the countdown is drawn from the server's `cooldown_until`,
// never from a timer started when this screen opened, because a local clock
// would drift away from the one enforcing the rule.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

/// Statuses where a run is in flight.
const Set<String> _busy = {'Queued', 'Running'};

class SapSyncBar extends StatefulWidget {
  const SapSyncBar({super.key});

  @override
  State<SapSyncBar> createState() => _SapSyncBarState();
}

class _SapSyncBarState extends State<SapSyncBar> {
  Map<String, dynamic> _s = const {};
  bool _loading = true;
  bool _asking = false;
  Timer? _tick;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _read();
    // Once a second, so the countdown and "12 minutes ago" stay honest without
    // asking the server anything.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final s = await Api.sapSyncStatus();
      if (!mounted) return;
      setState(() {
        _s = s;
        _loading = false;
      });
      if (_busy.contains('${s['status']}')) _startPolling();
    } catch (_) {
      // Silent. This is a freshness note beside the figures, not the reason
      // the screen exists — a failure here must not shout over the customer.
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Poll every 10 seconds until the run settles, then say what happened once.
  ///
  /// Ten seconds because a run takes about two minutes: prompt enough to feel
  /// live, rare enough that a screen left open is not hammering the site. The
  /// ceiling stops a poller that never writes back from spinning forever.
  void _startPolling() {
    if (_poll != null) return;
    var rounds = 0;
    _poll = Timer.periodic(const Duration(seconds: 10), (t) async {
      if (!mounted || ++rounds > 60) {
        t.cancel();
        _poll = null;
        return;
      }
      try {
        final s = await Api.sapSyncStatus();
        if (!mounted) return;
        setState(() => _s = s);
        if (!_busy.contains('${s['status']}')) {
          t.cancel();
          _poll = null;
          final msg = '${s['last_result_message'] ?? ''}'.trim();
          _snack(msg.isEmpty ? 'SAP sync ${s['status']}.' : msg);
        }
      } catch (_) {
        // Leave the loop running; a single dropped poll on a phone in a shop
        // is normal and the next one usually lands.
      }
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _request() async {
    setState(() => _asking = true);
    try {
      final r = await Api.requestSapSync();
      _snack('${r['message'] ?? 'Requested.'}');
      await _read();
      if (r['ok'] == true) _startPolling();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// How long ago, in words. "12 minutes ago" says more than a timestamp.
  String _relative(String? iso) {
    if (iso == null || iso.isEmpty || iso == 'null') return 'Never';
    final t = DateTime.tryParse(iso);
    if (t == null) return 'Never';
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'just now';
    if (m < 60) return '$m minute${m == 1 ? '' : 's'} ago';
    final h = m ~/ 60;
    if (h < 24) return '$h hour${h == 1 ? '' : 's'} ago';
    final d = h ~/ 24;
    return '$d day${d == 1 ? '' : 's'} ago';
  }

  String _mmss(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    final status = '${_s['status'] ?? 'Idle'}';
    final running = _busy.contains(status);

    final coolIso = '${_s['cooldown_until'] ?? ''}';
    final coolUntil = coolIso.isEmpty || coolIso == 'null'
        ? null
        : DateTime.tryParse(coolIso);
    final coolLeft =
        coolUntil == null ? 0 : coolUntil.difference(DateTime.now()).inSeconds;
    final cooling = coolLeft > 0;

    // A rep would only ever get "Not permitted" from the script, so they are
    // not offered the button at all.
    final mayAsk = Session.I.isGM || Session.I.isManager;

    final rows = int.tryParse('${_s['last_rows_changed'] ?? 0}') ?? 0;
    final note = '${_s['last_result_message'] ?? ''}'.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sync, size: 14, color: Colors.black45),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'From SAP: ${_relative('${_s['last_sync_at'] ?? ''}')}',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              if (mayAsk)
                TextButton(
                  onPressed:
                      (running || cooling || _asking) ? null : _request,
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32)),
                  child: Text(
                    running
                        ? 'Syncing…'
                        : cooling
                            ? 'Next in ${_mmss(coolLeft)}'
                            : 'Reload',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          if (mayAsk && note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                rows > 0 ? '$note · $rows changed' : note,
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),
            ),
        ],
      ),
    );
  }
}
