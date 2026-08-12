import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/proximity.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/widgets/proximity_gate.dart';

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

  /// An open visit somewhere other than here, or null. Held so the card can
  /// say so before the rep taps, rather than only when they are refused.
  Map<String, dynamic>? _openElsewhere;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _open =
      await Api.getOpenVisit(customer: widget.customer, lead: widget.lead);
    } catch (_) {}
    try {
      final any = await Api.getAnyOpenVisit();
      // The visit at this counter is not "elsewhere" — that one is what the
      // punch-out button is for.
      _openElsewhere = (any == null || (_open != null && any['name'] == _open!['name']))
          ? null
          : any;
    } catch (_) {
      _openElsewhere = null;
    }
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

    // Checked before the GPS fix, not after. Making a rep stand and wait for
    // satellites only to refuse them is a worse way to say the same thing.
    setState(() => _busy = true);
    try {
      final open = await Api.getAnyOpenVisit();
      if (open != null && mounted) {
        setState(() => _busy = false);
        return _showStillCheckedIn(open);
      }
    } catch (_) {
      // A failed lookup must not stop a rep working. The API refuses a second
      // visit anyway, so the worst case is the message arrives later and less
      // gracefully rather than a rep being stranded at a counter.
    }
    if (!mounted) return;

    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();

      // Punching in from somewhere else entirely is what this stops. Measured
      // against the nearest registered place — the shop's own pin or any of
      // its sites — so a rep at the godown is not refused for failing to stand
      // at the front counter.
      //
      // A null result means nothing usable is on record to measure against.
      // That is a data gap, not a rep in the wrong place, and refusing would
      // strand them at a counter they are genuinely standing in.
      final places = await Api.registeredPlacesFor(
          customer: widget.customer, lead: widget.lead);
      final near = nearestRegistered(pos.latitude, pos.longitude, places);
      if (near != null && near.metres > kPunchInRadiusMetres) {
        if (!mounted) return;
        setState(() => _busy = false);
        return _showTooFar(near.place.label, near.metres);
      }

      // Leads only. Established customers genuinely sit close together in a
      // town, and blocking a rep from starting a visit at a shop they already
      // sell to would stop real work to prevent a duplicate that cannot happen
      // — the customer is already on record.
      if (widget.lead != null) {
        if (!mounted) return;
        final clear = await ensureNothingNearby(
          context,
          lat: pos.latitude,
          lng: pos.longitude,
          subject: 'start a visit',
          exclude: {widget.lead!},
        );
        if (!clear || !mounted) return;
      }
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

  /// Says where the rep is still checked in, and since when.
  ///
  /// Named rather than just refused: a rep who forgot to punch out two shops
  /// ago cannot act on "you have a visit open" — they need to know which one,
  /// because that is the screen they have to go back to.
  Future<void> _showStillCheckedIn(Map<String, dynamic> open) {
    final where =
        '${open['customer'] ?? open['custom_lead'] ?? 'another place'}'.trim();
    final since = _fmtT(open['check_in_time']);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: const [
          Icon(Icons.timer_outlined, color: Color(0xFFB3261E)),
          SizedBox(width: 8),
          Expanded(child: Text('Still on a visit')),
        ]),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You have been checked in at $where since $since. '
                'You can only be on one visit at a time.',
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 10),
              const Text(
                'Go back and punch out there, then start this one.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ]),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Says how far off the rep is, and from what.
  ///
  /// The distance is quoted because it is the difference between "your GPS is
  /// drifting" and "you are in the wrong town", and the rep can tell those
  /// apart at a glance where the app cannot.
  Future<void> _showTooFar(String place, double metres) {
    final away = metres < 1000
        ? '${metres.round()} m'
        : '${(metres / 1000).toStringAsFixed(1)} km';
    final limit = kPunchInRadiusMetres >= 1000
        ? '${(kPunchInRadiusMetres / 1000).toStringAsFixed(0)} km'
        : '${kPunchInRadiusMetres.round()} m';
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: const [
          Icon(Icons.wrong_location_outlined, color: Color(0xFFB3261E)),
          SizedBox(width: 8),
          Expanded(child: Text('Too far to punch in')),
        ]),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You are $away from $place. A visit can only be started '
                'within $limit of where the place is registered.',
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 10),
              const Text(
                'If you are at the right shop, its saved location is wrong — '
                'ask your manager to have it captured again.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ]),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
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
          // Said on the card, not just when the button is tapped, so a rep who
          // forgot to punch out two shops ago finds out on arrival.
          if (!_loading && !open && _openElsewhere != null) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.timer_outlined,
                  size: 18, color: Color(0xFFB3261E)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Still checked in at '
                    '${_openElsewhere!['customer'] ?? _openElsewhere!['custom_lead'] ?? 'another place'}'
                    ' since ${_fmtT(_openElsewhere!['check_in_time'])}. '
                    'Punch out there first.',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFB3261E))),
              ),
            ]),
          ],
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

