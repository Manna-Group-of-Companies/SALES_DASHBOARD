import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';

class VisitPunchCard extends StatefulWidget {
  final String? customer;
  final String? lead;

  /// Whether the shop location has already been captured. A visit cannot start
  /// until it has — the rep captures the location first, then punches in. Left
  /// required so a new caller can't silently skip the gate.
  final bool locationCaptured;

  const VisitPunchCard(
      {super.key,
      this.customer,
      this.lead,
      required this.locationCaptured});
  @override
  State<VisitPunchCard> createState() => _VisitPunchCardState();
}

class _VisitPunchCardState extends State<VisitPunchCard> {
  Map<String, dynamic>? _open;
  bool _busy = false, _loading = true;
  String? _lastDuration;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _open =
      await Api.getOpenVisit(customer: widget.customer, lead: widget.lead);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _punchIn() async {
    if (!widget.locationCaptured) {
      return _snack('Capture the location first, then punch in.');
    }
    if (Session.I.salesPerson == null) {
      return _snack('No rep linked to this login.');
    }
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      await Api.punchInVisit(
          customer: widget.customer,
          lead: widget.lead,
          lat: pos.latitude,
          lng: pos.longitude);
      _snack('Punched in ✓');
      await _load();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _punchOut() async {
    if (_open == null) return;
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final mins = await Api.punchOutVisit(
        name: _open!['name'] as String,
        lat: pos.latitude,
        lng: pos.longitude,
        checkInTime: '${_open!['check_in_time'] ?? ''}',
      );
      _lastDuration = mins.toStringAsFixed(0);
      _snack('Punched out ✓ — ${mins.toStringAsFixed(0)} min');
      await _load();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtT(dynamic t) {
    final s = '$t';
    return s.length >= 16 ? s.substring(11, 16) : s;
  }

  String _elapsed() {
    try {
      final inT =
      DateTime.parse('${_open!['check_in_time']}'.replaceFirst(' ', 'T'));
      return '${DateTime.now().difference(inT).inMinutes} min';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _open != null;
    return Card(
      color: open ? const Color(0xFFE0F2F1) : const Color(0xFFF3F4F6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(open ? Icons.timer : Icons.timer_outlined,
                color: const Color(0xFFF46A21)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _loading
                    ? 'Visit timer...'
                    : open
                    ? 'On visit since ${_fmtT(_open!['check_in_time'])}  ·  ${_elapsed()}'
                    : (_lastDuration != null
                    ? 'Last visit: $_lastDuration min'
                    : 'Not on a visit'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          // Punching out is never gated — an already-open visit must always be
          // closable, even if the location was never captured.
          if (!_loading && !open && !widget.locationCaptured) ...[
            const SizedBox(height: 8),
            Row(children: const [
              Icon(Icons.info_outline, size: 18, color: Colors.black45),
              SizedBox(width: 8),
              Expanded(
                child: Text('Capture the location first to start a visit.',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ),
            ]),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: open
                ? FilledButton.icon(
              style:
              FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: _busy ? null : _punchOut,
              icon: const Icon(Icons.logout),
              label: const Padding(
                  padding: EdgeInsets.all(8), child: Text('Punch out')),
            )
                : FilledButton.icon(
              onPressed: _busy || _loading || !widget.locationCaptured
                  ? null
                  : _punchIn,
              icon: const Icon(Icons.login),
              label: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Punch in (start visit)')),
            ),
          ),
        ]),
      ),
    );
  }
}

