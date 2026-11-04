import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/proximity.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/pending_punches.dart';
import 'package:manna_field_sales/services/trip_tracker.dart';
import 'package:manna_field_sales/widgets/proximity_gate.dart';

class VisitPunchCard extends StatefulWidget {
  final String? customer;
  final String? lead;

  /// Whether the shop location has already been captured. A visit cannot start
  /// until it has — the rep captures the location first, then punches in. Left
  /// required so a new caller can't silently skip the gate.
  final bool locationCaptured;

  /// Re-captures the place at where the rep is standing now.
  ///
  /// Offered from inside the "too far" dialog because that is the only moment
  /// a rep learns the pin is wrong, and until this existed the advice they got
  /// there — ask the manager — was advice nobody could act on: the manager's
  /// queue only lists captures awaiting verification, and a manager capturing
  /// from the office would write the office.
  final VoidCallback? onLocationWrong;

  /// The place's own pin, from the row the screen already holds. Measured
  /// against when the full list of its pins cannot be fetched — no signal —
  /// so the 2 km check still runs offline rather than waving the punch
  /// through. See `services/pending_punches.dart`.
  final List<RegisteredPlace> fallbackPlaces;

  /// What to call the place on the unsent-punches list.
  final String? partyLabel;

  const VisitPunchCard(
      {super.key,
      this.customer,
      this.lead,
      required this.locationCaptured,
      this.onLocationWrong,
      this.fallbackPlaces = const [],
      this.partyLabel});
  @override
  State<VisitPunchCard> createState() => _VisitPunchCardState();
}

class _VisitPunchCardState extends State<VisitPunchCard> {
  Map<String, dynamic>? _open;
  bool _busy = false, _loading = true;

  /// Today's last finished visit here, read back on every load so it survives
  /// the rep leaving this screen and coming back.
  ({String checkIn, String checkOut, double minutes})? _last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// An open visit somewhere other than here, or null. Held so the card can
  /// say so before the rep taps, rather than only when they are refused.
  Map<String, dynamic>? _openElsewhere;

  /// True when a punch for this place is on the phone and not yet sent.
  bool _unsent = false;

  Future<void> _load() async {
    setState(() => _loading = true);
    // Two lookups that do not depend on each other, started together. This
    // card was the slowest thing on the customer screen, and half of that was
    // waiting for the first answer before asking the second question. Either
    // failing reads as "no visit", as before.
    final hereF = Api.getOpenVisit(customer: widget.customer, lead: widget.lead)
        .catchError((_) => null);
    final anyF = Api.getAnyOpenVisit().catchError((_) => null);
    final lastF =
        Api.getLastClosedVisit(customer: widget.customer, lead: widget.lead)
            .catchError((_) => null);
    final pendingF = PendingPunches.all();
    final serverHere = await hereF;
    final serverAny = await anyF;
    final serverLast = await lastF;
    final pending = await pendingF;
    // Punches still on the phone laid over what the server said, so a visit
    // punched in with no signal reads as open here — not as "Punch in" again.
    // The visit at this counter is not "elsewhere"; visitView sees to that.
    final view = PendingPunches.visitView(
      serverHere: serverHere,
      serverAny: serverAny,
      pending: pending,
      today: today(),
      customer: widget.customer,
      lead: widget.lead,
    );
    _open = view.here;
    _openElsewhere = view.elsewhere;
    _last = PendingPunches.lastVisitView(
      server: serverLast,
      pending: pending,
      today: today(),
      customer: widget.customer,
      lead: widget.lead,
    );
    _unsent = pending.any((p) =>
        p.isVisit &&
        ((widget.customer != null && p.customer == widget.customer) ||
            (widget.lead != null && p.lead == widget.lead) ||
            (_open?['name'] != null && p.docName == _open!['name'])));
    if (mounted) setState(() => _loading = false);
  }

  /// Puts a punch on the phone and says so in the words the rest of the app
  /// uses for unsent work: kept, not sent, will go by itself.
  Future<void> _queue(PunchKind kind, {
    required String at,
    required double lat,
    required double lng,
    double? accuracy,
    String? docName,
    String? dependsOn,
    String? punchInAt,
    bool checkNearby = false,
  }) async {
    await PendingPunches.add(
      kind: kind,
      at: at,
      lat: lat,
      lng: lng,
      accuracy: accuracy,
      docName: docName,
      dependsOn: dependsOn,
      punchInAt: punchInAt,
      customer: widget.customer,
      lead: widget.lead,
      partyLabel: widget.partyLabel,
      trip: kind == PunchKind.visitIn ? TripTracker.I.activeTrip.value : null,
      checkNearby: checkNearby,
    );
    _snack('No signal — saved on your phone at ${hhmm(at)}. '
        'It will be sent by itself when you have signal.');
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
      // Offline, getAnyOpenVisit answers from the last open visit the phone
      // saw, and the queue adds any visit punched in since without a signal.
      // A failed lookup is only the server's half: the queue's half is on the
      // phone and must still be checked, or a second visit is queued here
      // and refused once it is sent.
      final view = PendingPunches.visitView(
        serverAny: await Api.getAnyOpenVisit().catchError((_) => null),
        pending: await PendingPunches.all(),
        today: today(),
      );
      final open = view.elsewhere;
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
      // Asked for while the GPS settles rather than after it. The shop's pin
      // and its sites are two round trips, and they used to start only once
      // the fix was in — end to end with the slowest thing on the phone.
      // registeredPlacesFor never throws; it returns what it gathered.
      final placesF = Api.registeredPlacesFor(
          customer: widget.customer, lead: widget.lead);
      final pos = await getCurrentLocation();
      // Taken now, before any of the checks below spend time on the network:
      // this is the moment the rep pressed the button at the counter.
      final at = nowStamp();

      // Punching in from somewhere else entirely is what this stops. Measured
      // against the nearest registered place — the shop's own pin or any of
      // its sites — so a rep at the godown is not refused for failing to stand
      // at the front counter.
      //
      // A null result means nothing usable is on record to measure against.
      // That is a data gap, not a rep in the wrong place, and refusing would
      // strand them at a counter they are genuinely standing in.
      //
      // With no signal the full list cannot be read, so the shop's own pin
      // from the row on screen stands in. Its sites are not on the phone, so
      // a rep at a godown can be refused offline; that rounds the safe way —
      // the radius must not open up because the network is down.
      var places = await placesF;
      if (places.isEmpty) places = widget.fallbackPlaces;
      final near = nearestRegistered(pos.latitude, pos.longitude, places);
      if (near != null &&
          punchIsTooFar(near.metres, pos.accuracy,
              allowance: kMaxAccuracyAllowanceMetres)) {
        if (!mounted) return;
        setState(() => _busy = false);
        return _showTooFar(near.place.label, near.metres, pos.accuracy);
      }

      // Leads only. Established customers genuinely sit close together in a
      // town, and blocking a rep from starting a visit at a shop they already
      // sell to would stop real work to prevent a duplicate that cannot happen
      // — the customer is already on record.
      //
      // With no signal the check cannot run, and it must not be skipped. The
      // punch is queued with the check still owed; it runs when the punch is
      // sent, and the visit is only recorded if it passes.
      var checkLater = false;
      if (widget.lead != null) {
        if (!mounted) return;
        final gate = await nearbyGate(
          context,
          lat: pos.latitude,
          lng: pos.longitude,
          subject: 'start a visit',
          exclude: {widget.lead!},
        );
        if (gate == NearbyGate.blocked || !mounted) return;
        checkLater = gate == NearbyGate.unreachable;
      }

      Future<void> queueIt() => _queue(PunchKind.visitIn,
          at: at,
          lat: pos.latitude,
          lng: pos.longitude,
          accuracy: pos.accuracy,
          checkNearby: checkLater);

      if (checkLater) {
        // Not even tried live. A signal that came back in the last second
        // would write the visit with its duplicate check never run.
        await queueIt();
      } else {
        try {
          await Api.punchInVisit(
              customer: widget.customer,
              lead: widget.lead,
              lat: pos.latitude,
              lng: pos.longitude,
              at: at);
          _snack('Punched in ✓');
        } catch (e) {
          if (!isNetworkFailure(e)) rethrow;
          await queueIt();
        }
      }
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
    // The readable name. A visit stores the party as a docname, and for a lead
    // that is CRM-LEAD-2026-02014 — which names nothing a rep can recognise
    // while standing in front of the next customer. Api.getAnyOpenVisit
    // resolves it into party_label; the docname is the fallback.
    final where = '${open['party_label'] ?? open['customer'] ?? open['custom_lead'] ?? 'another place'}'
        .trim();
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
  Future<void> _showTooFar(String place, double metres, double accuracy) {
    final away = metres < 1000
        ? '${metres.round()} m'
        : '${(metres / 1000).toStringAsFixed(1)} km';
    final limit = kPunchInRadiusMetres >= 1000
        ? '${(kPunchInRadiusMetres / 1000).toStringAsFixed(0)} km'
        : '${kPunchInRadiusMetres.round()} m';

    // A fix this coarse is the likeliest explanation of the distance, and the
    // rep can act on it — going outside costs them a minute. Telling them the
    // shop's pin is wrong instead sends them to correct a record that may be
    // perfectly good.
    final coarse = accuracy > kMaxCaptureAccuracyMetres;
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
              Text(
                coarse
                    ? 'Your phone only knows where it is to within about '
                        '${accuracy.round()} m, so this distance may be wrong. '
                        'Step outside, give GPS a few seconds, and try again.'
                    : widget.onLocationWrong == null
                        ? 'If you are at the right shop, its saved location is '
                            'wrong — ask your manager to have it captured again.'
                        : 'If you are standing at the right shop, its saved '
                            'location is wrong. Fix it here and punch in again.',
                style: const TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ]),
        actions: [
          // Withheld while the fix is coarse. Offering to rewrite the pin from
          // a position the phone itself doubts is how a good location becomes
          // a bad one.
          if (widget.onLocationWrong != null && !coarse)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onLocationWrong!();
              },
              child: const Text('Location is wrong'),
            ),
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _punchOut() async {
    final open = _open;
    if (open == null) return;
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      final at = nowStamp();
      final checkIn = '${open['check_in_time'] ?? ''}';
      final name = open['name'];
      if (name is String && name.isNotEmpty) {
        try {
          final mins = await Api.punchOutVisit(
            name: name,
            lat: pos.latitude,
            lng: pos.longitude,
            checkInTime: checkIn,
            at: at,
          );
          _snack('Punched out ✓ — ${mins.toStringAsFixed(0)} min');
        } catch (e) {
          if (!isNetworkFailure(e)) rethrow;
          await _queue(PunchKind.visitOut,
              at: at,
              lat: pos.latitude,
              lng: pos.longitude,
              accuracy: pos.accuracy,
              docName: name,
              punchInAt: checkIn);
        }
      } else {
        // The punch-in is itself still on the phone, so there is no visit on
        // the server to close yet. Not tried live: this waits behind it and
        // is pointed at the visit it creates when the two are sent.
        await _queue(PunchKind.visitOut,
            at: at,
            lat: pos.latitude,
            lng: pos.longitude,
            accuracy: pos.accuracy,
            dependsOn: '${open['pending_in']}',
            punchInAt: checkIn);
      }
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
                    : (_last != null
                    ? 'Last visit: ${_fmtT(_last!.checkIn)}–'
                        '${_fmtT(_last!.checkOut)}  ·  '
                        '${_last!.minutes.toStringAsFixed(0)} min'
                    : 'Not on a visit'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          // A punch here that is still on the phone. Said so the rep knows the
          // office cannot see it yet — and does not punch again to make sure.
          if (!_loading && _unsent) ...[
            const SizedBox(height: 6),
            Row(children: const [
              Icon(Icons.cloud_off, size: 16, color: Color(0xFFB35309)),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Saved on your phone, not sent yet — it goes by itself '
                    'when you have signal.',
                    style: TextStyle(fontSize: 12, color: Color(0xFFB35309))),
              ),
            ]),
          ],
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
                    '${_openElsewhere!['party_label'] ?? _openElsewhere!['customer'] ?? _openElsewhere!['custom_lead'] ?? 'another place'}'
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

