// Punches taken with no signal, held on the phone until there is one.
//
// A rep's day starts and ends with a punch, and a good share of the shops they
// punch in at are in sheds and back streets with no bars. A punch that needed
// the network refused them there — "No connection" — and the rep either
// walked back out to the road to find a signal or did not punch at all, and
// HR saw a missed punch for a day that was worked.
//
// So a punch is a fact recorded on the phone first: the time, the place and
// what it is a punch of. When the write cannot reach the server it waits here
// and is sent when the signal comes back, keeping the time it was taken.
//
// WHY THIS IS SAFE WHEN ORDERS ARE NOT QUEUED
//
// `offline_cache.dart` explains why an order is never sent behind the rep's
// back: it promises stock, and the promise can be gone by the time it lands.
// A punch promises nothing. It records where somebody was and when, which is
// as true an hour later as it was at the time.
//
// WHAT IS STILL CHECKED, AND WHEN
//
// - The attendance window is judged on the punch's own time, at the punch and
//   again when it is sent — a 21:20 punch-out sent at 22:00 is still in time.
// - The 2 km punch-in radius is judged at the punch, against the pins already
//   on the phone. Offline that is the shop's own pin and not its sites, so a
//   rep at a godown with no signal can be refused where they would have been
//   let in online. Rounded that way on purpose: the radius exists to stop a
//   punch from the wrong place, and it must not open up for want of a signal.
// - The duplicate-lead check cannot run without the server, and
//   `proximity_gate.dart` refuses to let a missing network open it. So it is
//   not skipped: it runs when the punch is SENT, and a visit that fails it is
//   never recorded — it stays here, with the reason, for the rep to discard.
// - One visit at a time is judged against the last open visit the phone saw
//   plus what is waiting here, and again by the server when the punch is sent.
//
// A punch is never silently dropped. One the server will not take stays here
// with the reason and is retried on every send, until it goes or the rep
// discards it.
//
// Punches belong to the rep who made them. Signing out asks first, then
// deletes them — the next person to use the handset must not send them.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';

enum PunchKind { attendanceIn, attendanceOut, visitIn, visitOut }

/// A queued punch the app itself refused to send — a lead visit that failed
/// its duplicate check once the check could finally run. Carries its own
/// sentence; `humanError` shows it as written.
class PunchRefused implements Exception {
  final String message;
  const PunchRefused(this.message);
  @override
  String toString() => message;
}

class PendingPunch {
  /// Local id. What [PendingPunch.dependsOn] points at, and what discarding
  /// matches on.
  final String id;
  final PunchKind kind;
  final String salesPerson;

  /// `yyyy-MM-dd HH:mm:ss`, off the server's clock at the moment of the punch.
  /// Taken here, not on arrival: a punch sent two hours late records when the
  /// rep was there, not when they found a signal.
  final String at;

  final double lat;
  final double lng;

  /// What the phone said its fix was good to, in metres. Kept for whoever has
  /// to judge a disputed punch; the server has no field for it yet.
  final double? accuracy;

  /// The server document a punch-out closes — the Attendance Log or the Sales
  /// Visit. Null while the punch-in it closes is itself still on the phone.
  final String? docName;

  /// The queued punch-in this punch-out closes, when that punch-in has not
  /// reached the server and so has no [docName] yet. Resolved when it is sent.
  final String? dependsOn;

  /// For a punch-out, when the matching punch-in happened — what its hours or
  /// minutes are measured from.
  final String? punchInAt;

  final String? customer;
  final String? lead;

  /// What to call the place, for the rep's list. A lead's docname
  /// (CRM-LEAD-2026-02014) names nothing a rep would recognise.
  final String? partyLabel;

  /// The trip running when the visit started, so the visit lands on the trip
  /// the rep was actually on rather than whichever is active when it is sent.
  final String? trip;

  /// True on a lead visit whose duplicate check could not run at the punch.
  /// The check runs when it is sent instead — see the header.
  final bool checkNearby;

  /// Why the last send failed, in words fit for the rep. Null when it has
  /// only been waiting for a signal.
  final String? lastError;

  final DateTime savedAt;

  const PendingPunch({
    required this.id,
    required this.kind,
    required this.salesPerson,
    required this.at,
    required this.lat,
    required this.lng,
    required this.savedAt,
    this.accuracy,
    this.docName,
    this.dependsOn,
    this.punchInAt,
    this.customer,
    this.lead,
    this.partyLabel,
    this.trip,
    this.checkNearby = false,
    this.lastError,
  });

  bool get isIn =>
      kind == PunchKind.attendanceIn || kind == PunchKind.visitIn;
  bool get isVisit => kind == PunchKind.visitIn || kind == PunchKind.visitOut;

  /// The day the punch belongs to, `yyyy-MM-dd`.
  String get date => at.length >= 10 ? at.substring(0, 10) : at;

  /// Copies with the given fields changed. [clearDependsOn] and [clearError]
  /// exist because a plain null argument cannot mean "set to null" here.
  PendingPunch copyWith({
    String? docName,
    bool clearDependsOn = false,
    String? lastError,
    bool clearError = false,
  }) =>
      PendingPunch(
        id: id,
        kind: kind,
        salesPerson: salesPerson,
        at: at,
        lat: lat,
        lng: lng,
        savedAt: savedAt,
        accuracy: accuracy,
        docName: docName ?? this.docName,
        dependsOn: clearDependsOn ? null : dependsOn,
        punchInAt: punchInAt,
        customer: customer,
        lead: lead,
        partyLabel: partyLabel,
        trip: trip,
        checkNearby: checkNearby,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'sales_person': salesPerson,
        'at': at,
        'lat': lat,
        'lng': lng,
        'saved_at': savedAt.toIso8601String(),
        if (accuracy != null) 'accuracy': accuracy,
        if (docName != null) 'doc_name': docName,
        if (dependsOn != null) 'depends_on': dependsOn,
        if (punchInAt != null) 'punch_in_at': punchInAt,
        if (customer != null) 'customer': customer,
        if (lead != null) 'lead': lead,
        if (partyLabel != null) 'party_label': partyLabel,
        if (trip != null) 'trip': trip,
        if (checkNearby) 'check_nearby': true,
        if (lastError != null) 'last_error': lastError,
      };

  /// Null for anything that cannot be sent — no kind, no time, no position.
  /// Such a row would sit at the head of the queue for ever.
  static PendingPunch? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}';
    final at = '${j['at'] ?? ''}';
    PunchKind? kind;
    for (final k in PunchKind.values) {
      if (k.name == j['kind']) kind = k;
    }
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (id.isEmpty || at.length < 19 || kind == null || lat == null || lng == null) {
      return null;
    }
    String? s(String key) {
      final v = j[key];
      return v == null ? null : '$v';
    }

    return PendingPunch(
      id: id,
      kind: kind,
      salesPerson: '${j['sales_person'] ?? ''}',
      at: at,
      lat: lat,
      lng: lng,
      savedAt: DateTime.tryParse('${j['saved_at'] ?? ''}') ?? serverNow(),
      accuracy: (j['accuracy'] as num?)?.toDouble(),
      docName: s('doc_name'),
      dependsOn: s('depends_on'),
      punchInAt: s('punch_in_at'),
      customer: s('customer'),
      lead: s('lead'),
      partyLabel: s('party_label'),
      trip: s('trip'),
      checkNearby: j['check_nearby'] == true,
      lastError: s('last_error'),
    );
  }
}

/// What came of one attempt to send the queue.
class PunchFlushResult {
  final int sent;

  /// Punches the server refused this time, with their reasons.
  final List<PendingPunch> failed;

  /// True when sending stopped because the network went. Everything not yet
  /// sent is still queued, untouched.
  final bool stoppedOffline;

  const PunchFlushResult(this.sent, this.failed, this.stoppedOffline);

  static const nothing = PunchFlushResult(0, [], false);
}

class PendingPunches {
  static const _key = 'pendingPunches';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// Counts adds within this run, so two punches in one clock tick still get
  /// different ids — the id is what discarding matches on.
  static int _seq = 0;

  /// This rep's punches, in the order they happened. Sent in that order too:
  /// a punch-out sent before its punch-in has nothing to close.
  static Future<List<PendingPunch>> all() async {
    final me = Session.I.salesPerson;
    final out = (await _raw())
        .where((p) => me == null || p.salesPerson == me)
        .toList()
      ..sort((a, b) {
        final c = a.at.compareTo(b.at);
        return c != 0 ? c : a.savedAt.compareTo(b.savedAt);
      });
    return out;
  }

  static Future<int> count() async => (await all()).length;

  /// Records a punch. [salesPerson] defaults to whoever is signed in.
  static Future<PendingPunch> add({
    required PunchKind kind,
    required String at,
    required double lat,
    required double lng,
    double? accuracy,
    String? docName,
    String? dependsOn,
    String? punchInAt,
    String? customer,
    String? lead,
    String? partyLabel,
    String? trip,
    bool checkNearby = false,
  }) async {
    final existing = await _raw();
    final now = serverNow();
    String id;
    do {
      id = 'punch-${now.microsecondsSinceEpoch}-${_seq++}';
    } while (existing.any((p) => p.id == id));

    final p = PendingPunch(
      id: id,
      kind: kind,
      salesPerson: Session.I.salesPerson ?? '',
      at: at,
      lat: lat,
      lng: lng,
      savedAt: now,
      accuracy: accuracy,
      docName: docName,
      dependsOn: dependsOn,
      punchInAt: punchInAt,
      customer: customer,
      lead: lead,
      partyLabel: partyLabel,
      trip: trip,
      checkNearby: checkNearby,
    );
    await _replaceAll([...existing, p]);
    return p;
  }

  /// Throws away a punch, and every punch-out waiting on it. A punch-out whose
  /// punch-in will never be sent has nothing to close, and left behind it
  /// would wait for ever.
  static Future<void> discard(String id) async {
    final all = await _raw();
    final drop = <String>{id};
    // Chains are one deep in practice, but following them costs nothing.
    var grew = true;
    while (grew) {
      grew = false;
      for (final p in all) {
        if (p.dependsOn != null &&
            drop.contains(p.dependsOn) &&
            drop.add(p.id)) {
          grew = true;
        }
      }
    }
    await _replaceAll(all.where((p) => !drop.contains(p.id)).toList());
  }

  /// Wipes every punch on the handset, not just this rep's. Sign-out only,
  /// and only after the rep has been told what is about to go.
  static Future<void> clear() async {
    try {
      await (await _prefs).remove(_key);
    } catch (_) {}
  }

  static Future<PunchFlushResult>? _inFlight;

  /// Sends this rep's punches, oldest first.
  ///
  /// [send] does the real work and returns the server document the punch
  /// created or wrote to; a punch-in's answer is handed to the punch-outs
  /// waiting on it. A punch that sends is removed at once, one at a time, so
  /// a phone that dies half-way through re-sends at most the one in hand —
  /// and [send] finds that one already on the server rather than doubling it.
  ///
  /// The network going stops the run and leaves everything else exactly as
  /// it was: the rest would only fail the same way. A refusal does not stop
  /// it. The refused punch keeps its reason and the punch-outs waiting on it
  /// stay put; everything else carries on, because one bad punch must not
  /// hold a day's good ones hostage.
  ///
  /// One run at a time. The home screen asks on resume, on refresh and on a
  /// timer, and two runs overlapping would send the same punch twice.
  static Future<PunchFlushResult> flush(
    Future<String?> Function(PendingPunch p) send, {
    String Function(Object error)? describe,
  }) {
    return _inFlight ??=
        _flush(send, describe).whenComplete(() => _inFlight = null);
  }

  static Future<PunchFlushResult> _flush(
    Future<String?> Function(PendingPunch p) send,
    String Function(Object error)? describe,
  ) async {
    final queue = await all();
    if (queue.isEmpty) return PunchFlushResult.nothing;

    final resolved = <String, String>{}; // punch-in id -> server document
    final failed = <PendingPunch>[];
    var sent = 0;

    for (var p in queue) {
      final waitingOn = p.dependsOn;
      if (waitingOn != null) {
        final doc = resolved[waitingOn];
        // Its punch-in has not gone — refused this run, or still queued
        // behind something that was. Nothing to close yet.
        if (doc == null) continue;
        p = p.copyWith(docName: doc, clearDependsOn: true);
        await _update(p);
      }

      try {
        final doc = await send(p);
        final resolvedDoc =
            (p.isIn && doc != null && doc.isNotEmpty) ? doc : null;
        // The punch-outs waiting on this one are pointed at its record in
        // the same write that removes it. Left to the loop, a run that
        // stopped before reaching them — the signal going, the phone dying —
        // would leave them waiting on a punch-in that is no longer queued,
        // and they would never be sent.
        await _settle(p.id, resolvedDoc);
        sent++;
        if (resolvedDoc != null) resolved[p.id] = resolvedDoc;
      } catch (e) {
        if (isNetworkFailure(e)) {
          return PunchFlushResult(sent, failed, true);
        }
        final why = describe != null ? describe(e) : '$e';
        final kept = p.copyWith(lastError: why);
        await _update(kept);
        failed.add(kept);
      }
    }
    return PunchFlushResult(sent, failed, false);
  }

  // -- What the screens should show ------------------------------------------
  //
  // A queued punch has to read as done on the screen that made it, or the rep
  // punches again. These lay the queue over the server's last word. Pure, so
  // they are tested without a network.

  /// Today's attendance as the rep should see it: [server]'s row, or null,
  /// with any punches still on the phone laid over it.
  ///
  /// Adds `pending_in` / `pending_out` holding the queue id of a punch that has
  /// not been sent, so the card can say "not sent yet" and a punch-out knows
  /// which queued punch-in it closes.
  static Map<String, dynamic>? attendanceView(
      Map<String, dynamic>? server, List<PendingPunch> pending, String today) {
    Map<String, dynamic>? view =
        server == null ? null : Map<String, dynamic>.from(server);
    for (final p in pending) {
      if (p.date != today) continue;
      if (p.kind == PunchKind.attendanceIn) {
        // The server's own punch-in wins over a queued one: it got there
        // first, and the queued one will find it and stand down when sent.
        final hasIn = '${view?['punch_in_time'] ?? ''}'.trim();
        if (hasIn.isEmpty || hasIn == 'null') {
          view = {
            ...?view,
            'attendance_date': today,
            'status': 'Punched In',
            'punch_in_time': p.at,
            'pending_in': p.id,
          };
        }
      } else if (p.kind == PunchKind.attendanceOut && view != null) {
        view['status'] = 'Punched Out';
        view['punch_out_time'] = p.at;
        view['working_hours'] =
            hoursBetween('${view['punch_in_time'] ?? ''}', p.at);
        view['pending_out'] = p.id;
      }
    }
    return view;
  }

  /// The open visit at one party, and the open visit anywhere else, as the
  /// rep should see them once the queue is laid over [serverHere] and
  /// [serverAny].
  ///
  /// A visit punched in on the phone and not out reads as open; a server
  /// visit with a punch-out waiting on the phone reads as closed. A queued
  /// visit carries `pending_in` and no `name`, because it has none yet.
  /// Pass no party to ask only "is the rep on a visit anywhere".
  static ({Map<String, dynamic>? here, Map<String, dynamic>? elsewhere})
      visitView({
    Map<String, dynamic>? serverHere,
    Map<String, dynamic>? serverAny,
    required List<PendingPunch> pending,
    required String today,
    String? customer,
    String? lead,
  }) {
    final visits = pending.where((p) => p.isVisit).toList();
    final closedOnServer = {
      for (final p in visits)
        if (p.kind == PunchKind.visitOut && p.docName != null) p.docName!
    };
    final closedOnPhone = {
      for (final p in visits)
        if (p.kind == PunchKind.visitOut && p.dependsOn != null) p.dependsOn!
    };

    bool open(Map<String, dynamic>? v) =>
        v != null && !closedOnServer.contains('${v['name']}');

    // The last visit punched in on the phone and not out — at most one, since
    // a second is refused while the first is open.
    PendingPunch? phoneOpen;
    for (final p in visits) {
      if (p.kind == PunchKind.visitIn &&
          p.date == today &&
          !closedOnPhone.contains(p.id)) {
        phoneOpen = p;
      }
    }

    Map<String, dynamic>? asVisit(PendingPunch p) => {
          'name': null,
          'pending_in': p.id,
          'check_in_time': p.at,
          'customer': p.customer,
          'custom_lead': p.lead,
          'party_label': p.partyLabel ?? p.customer ?? p.lead,
        };

    bool isHere(PendingPunch p) =>
        (customer != null && p.customer == customer) ||
        (lead != null && p.lead == lead);

    var here = open(serverHere) ? serverHere : null;

    // The rep's open visit anywhere, when it is at this party, IS the visit
    // here. Online the two lookups agree anyway. With weak signal they do not:
    // the lookup for this party has no offline copy and comes back empty,
    // while the one for anywhere answers from the last visit the phone saw —
    // and the card told a rep standing in the shop they were "still checked
    // in at" that same shop, with no Punch out button.
    final serverAnyIsHere = serverAny != null &&
        ((customer != null && serverAny['customer'] == customer) ||
            (lead != null && serverAny['custom_lead'] == lead));
    if (here == null && serverAnyIsHere && open(serverAny)) here = serverAny;

    Map<String, dynamic>? elsewhere;
    if (phoneOpen != null && isHere(phoneOpen)) {
      here = asVisit(phoneOpen);
    } else if (phoneOpen != null) {
      elsewhere = asVisit(phoneOpen);
    }
    if (elsewhere == null && open(serverAny) && !serverAnyIsHere) {
      final sameAsHere =
          here != null && here['name'] != null && here['name'] == serverAny!['name'];
      if (!sameAsHere) elsewhere = serverAny;
    }
    return (here: here, elsewhere: elsewhere);
  }

  /// Today's last finished visit at one party, as the rep should see it:
  /// [server]'s last closed visit there, or a punch-out still on the phone if
  /// that came later. Null when neither exists.
  ///
  /// The phone's punch-out counts so a visit closed with no signal still reads
  /// as finished, with its minutes, rather than vanishing from the card.
  static ({String checkIn, String checkOut, double minutes})? lastVisitView({
    Map<String, dynamic>? server,
    required List<PendingPunch> pending,
    required String today,
    String? customer,
    String? lead,
  }) {
    ({String checkIn, String checkOut, double minutes})? best;

    if (server != null) {
      final checkIn = '${server['check_in_time'] ?? ''}';
      final checkOut = '${server['check_out_time'] ?? ''}';
      if (checkOut.length >= 19 && checkOut.startsWith(today)) {
        final stored = server['custom_duration_minutes'];
        best = (
          checkIn: checkIn,
          checkOut: checkOut,
          minutes: stored is num && stored > 0
              ? stored.toDouble()
              : minutesBetween(checkIn, checkOut),
        );
      }
    }

    for (final p in pending) {
      if (p.kind != PunchKind.visitOut || p.date != today) continue;
      final here = (customer != null && p.customer == customer) ||
          (lead != null && p.lead == lead);
      if (!here) continue;
      if (best != null && p.at.compareTo(best.checkOut) <= 0) continue;
      final checkIn = p.punchInAt ?? '';
      best = (
        checkIn: checkIn,
        checkOut: p.at,
        minutes: minutesBetween(checkIn, p.at),
      );
    }
    return best;
  }

  /// Minutes between two `yyyy-MM-dd HH:mm:ss` stamps, never negative — the
  /// sum the visit punch-out writes. Not [hoursBetween] times 60: that rounds
  /// to hundredths of an hour first, and a 25-minute visit comes out 25.2.
  static double minutesBetween(String from, String to) {
    final a = DateTime.tryParse(from.replaceFirst(' ', 'T'));
    final b = DateTime.tryParse(to.replaceFirst(' ', 'T'));
    if (a == null || b == null) return 0;
    final m = b.difference(a).inSeconds / 60.0;
    return m < 0 ? 0 : m;
  }

  /// Hours between two `yyyy-MM-dd HH:mm:ss` stamps, to two places, never
  /// negative — the sum the attendance punch-out writes.
  static double hoursBetween(String from, String to) {
    final a = DateTime.tryParse(from.replaceFirst(' ', 'T'));
    final b = DateTime.tryParse(to.replaceFirst(' ', 'T'));
    if (a == null || b == null) return 0;
    final h = b.difference(a).inMinutes / 60.0;
    return h < 0 ? 0 : double.parse(h.toStringAsFixed(2));
  }

  // -- storage ---------------------------------------------------------------

  /// Every punch on the handset, including other reps'. Writes go through
  /// this so saving one never drops another's.
  static Future<List<PendingPunch>> _raw() async {
    try {
      final s = (await _prefs).getString(_key);
      if (s == null || s.isEmpty) return [];
      final list = jsonDecode(s);
      if (list is! List) return [];
      return list.map(PendingPunch.fromJson).whereType<PendingPunch>().toList();
    } catch (_) {
      return [];
    }
  }

  /// Removes a sent punch and, when it created a record, hands that record to
  /// every punch-out waiting on it.
  static Future<void> _settle(String id, String? doc) async => _replaceAll([
        for (final o in await _raw())
          if (o.id != id)
            (doc != null && o.dependsOn == id)
                ? o.copyWith(docName: doc, clearDependsOn: true)
                : o,
      ]);

  static Future<void> _update(PendingPunch p) async => _replaceAll(
      (await _raw()).map((o) => o.id == p.id ? p : o).toList());

  static Future<void> _replaceAll(List<PendingPunch> list) async {
    await (await _prefs)
        .setString(_key, jsonEncode(list.map((p) => p.toJson()).toList()));
  }
}
