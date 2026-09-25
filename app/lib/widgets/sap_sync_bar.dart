// How fresh the credit figures are, and — for those allowed — a way to refresh.
//
// WHY IT SITS WITH THE CREDIT FIGURES
//
// The limit and the outstanding above it are copied from SAP, and from
// 24 September 2026 only when somebody asks — this button, or the Sync button
// on every screen; nothing runs on a timer. A limit raised in SAP this morning
// is not here until someone does, and a rep standing in the shop has no way of
// knowing whether the number they are being refused by is today's. Saying when
// it was last synced answers that; the button acts on the answer.
//
// WHO SEES THE BUTTON
//
// The Manna Treads team, and nobody else. Every rep on it, not just the
// manager — a rep standing in a shop is exactly who a stale credit limit
// blocks, so they are the ones who most need to refresh it.
//
// Retreads and UAE are excluded because the sync reads ONE company database,
// MANNA_TREADS_LIVE. A Retreads rep pressing this would spend the SAP login
// and the cooldown on a book their own customers are not in, and read
// "0 changed" every time without being told why.
//
// `manna_sap_request_sync` enforces the same test server-side, on company and
// not on role — "Sales Manager" cannot discriminate here, since the UAE and
// Retreads managers both hold it. This only decides whether to offer the
// button, never whether it works.
//
// Everyone else still sees the freshness line, because knowing the figure is
// three days old is useful even when you cannot do anything about it.
//
// THE COOLDOWN SPACES RUNS; IT NEVER REFUSES ONE
//
// It was 25 minutes because leaked Service Layer sessions aged out at SAP's
// 30-minute idle timeout and a login inside that window returned HTTP 500. The
// sync script now always logs out in a finally, and on 9 September 2026 SAP was
// verified handling back-to-back logins and six consecutive runs with no gap,
// each under ten seconds. It is 2 minutes now, purely so a double-tap cannot
// stack logins.
//
// Since 24 September 2026 a tap inside it is queued, not refused: the office
// poller runs it as soon as the pause is over, and the Server Script's message
// says how long that is. So the button stays live. The pause is kept on the
// office server, where nothing on a phone can reach it.

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
    // Once a second, so "12 minutes ago" stays honest without asking the
    // server anything.
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

  /// Poll every 3 seconds until the run settles, then say what happened once.
  ///
  /// Three, because a run now finishes in about ten seconds — at the old
  /// ten-second interval a sync that had already succeeded sat looking
  /// unfinished for most of its own duration. The ceiling stops a poller that
  /// never writes back from spinning forever.
  void _startPolling() {
    if (_poll != null) return;
    var rounds = 0;
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (!mounted || ++rounds > 100) {
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
      // Always queued; the server's message says when it will run.
      final r = await Api.requestSapSync();
      _snack('${r['message'] ?? 'Requested.'}');
      await _read();
      _startPolling();
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    final status = '${_s['status'] ?? 'Idle'}';
    final running = _busy.contains(status);

    // Mirrors the Server Script: the Manna Treads book, whether this login is
    // a rep in it or the manager over it. Anyone else would only ever get
    // "Not permitted", and a button that always fails is worse than no button.
    final mayAsk = Session.I.isTreadsUnit;

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
                  onPressed: (running || _asking) ? null : _request,
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32)),
                  child: Text(
                    running ? 'Fetching…' : 'Reload',
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
