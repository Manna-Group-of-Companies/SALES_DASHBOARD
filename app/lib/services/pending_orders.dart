// Orders composed with no signal, held until there is one.
//
// A draft here is explicitly *not* an order. Nothing is reserved, no customer
// has been promised anything, and the rep is told so in those words. That
// honesty is the whole design: stock is only really committed once SAP
// has the order, and pretending otherwise at the counter is how a customer
// gets promised rolls that another rep has already taken.
//
// So the deal offered to a rep with no bars is "type it now, send it when you
// have signal, and find out then whether the stock is still there" — which
// beats both losing the order and being lied to about it.
//
// Drafts belong to the rep who typed them and are cleared on sign-out, so a
// shared handset never carries one person's orders into another's session.
//
// SENT BY ITSELF WHEN THE SIGNAL IS BACK (the user, 11 Nov 2026). They used to
// wait for the rep to press Send, because an order once booked minimum stock
// on the phone; nothing has been booked on the phone since 17 Sep 2026 — SAP
// commits stock, and every order still waits for the manager. So the home
// screen sends them on the same one-minute retry as punches. A draft the
// server refuses is not retried by itself: it waits, with the reason, for the
// rep to send it again or discard it.
//
// SAP PRICES WITH NO SIGNAL. A Manna Treads per-kg line takes SAP's price and
// nothing else (10 Nov 2026), and with no signal there is none to take. Such a
// line is kept with no price and named in [PendingOrder.sapPending]; SAP's
// price is put on it when the draft is sent ([PendingOrders.priceFromSap]),
// and a product SAP still has no price for keeps the draft back, refused.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/models/sap_rates.dart';

/// A draft the app will not send as it stands, with the sentence to show.
class OrderRefused implements Exception {
  final String message;
  const OrderRefused(this.message);
  @override
  String toString() => message;
}

/// Why a kept order was held when it was sent: the customer is over their
/// credit limit as they stand now, and the order has no commitment. Unsent
/// Orders offers to add one on a draft refused with exactly this sentence.
const String kNeedsCommitmentNow =
    "Now over the customer's credit limit. Add the customer's commitment, "
    'then send it again.';

class PendingOrder {
  /// Local id. Not an order number — this has never reached the server.
  final String id;
  final String customer;
  final String customerName;
  final String deliveryDate;
  final List<Map<String, dynamic>> items;
  final String salesPerson;
  final DateTime savedAt;

  /// True when the party is a lead rather than a customer. Decides which
  /// order the draft becomes when it is finally sent.
  final bool isLead;

  /// Why the last send attempt failed, in the words the rep was shown.
  final String? lastError;

  /// What the customer committed to, when the order takes them past their
  /// credit limit — asked at the counter, and carried with the draft so it is
  /// not lost between the shop and the signal. See credit_commitment.json.
  final String? commitment;
  final String? commitmentDue;

  /// Who pays the courier, Paid or To Pay (core/delivery_mode.dart).
  final String? deliveryMode;

  /// Lines saved with no signal that take SAP's price when sent, by item code:
  /// `{'f': rate per kg -> line rate factor, 'n': product name}`.
  final Map<String, Map<String, dynamic>> sapPending;

  /// True when the server (or the app) said no to it, rather than the signal
  /// failing. Such a draft is not sent again by itself.
  final bool refused;

  const PendingOrder({
    required this.id,
    required this.customer,
    required this.customerName,
    required this.deliveryDate,
    required this.items,
    required this.salesPerson,
    required this.savedAt,
    this.isLead = false,
    this.lastError,
    this.commitment,
    this.commitmentDue,
    this.deliveryMode,
    this.sapPending = const {},
    this.refused = false,
  });

  double get total => items.fold(
      0.0,
      (sum, i) =>
          sum +
          ((i['qty'] as num?)?.toDouble() ?? 0) *
              ((i['rate'] as num?)?.toDouble() ?? 0));


  Map<String, dynamic> toJson() => {
        'id': id,
        'customer': customer,
        'customer_name': customerName,
        'delivery_date': deliveryDate,
        'items': items,
        'sales_person': salesPerson,
        'saved_at': savedAt.toIso8601String(),
        if (isLead) 'is_lead': true,
        if (lastError != null) 'last_error': lastError,
        if (commitment != null) 'commitment': commitment,
        if (commitmentDue != null) 'commitment_due': commitmentDue,
        if (deliveryMode != null) 'delivery_mode': deliveryMode,
        if (sapPending.isNotEmpty) 'sap_pending': sapPending,
        if (refused) 'refused': true,
      };

  static PendingOrder? fromJson(dynamic json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) return null;
    return PendingOrder(
      id: id,
      customer: '${json['customer'] ?? ''}',
      customerName: '${json['customer_name'] ?? ''}',
      deliveryDate: '${json['delivery_date'] ?? ''}',
      items: _rows(json['items']),
      salesPerson: '${json['sales_person'] ?? ''}',
      savedAt: DateTime.tryParse('${json['saved_at'] ?? ''}') ?? serverNow(),
      isLead: json['is_lead'] == true,
      lastError: json['last_error'] as String?,
      commitment: json['commitment'] as String?,
      commitmentDue: json['commitment_due'] as String?,
      deliveryMode: json['delivery_mode'] as String?,
      sapPending: {
        if (json['sap_pending'] is Map)
          for (final e in (json['sap_pending'] as Map).entries)
            if (e.value is Map) '${e.key}': Map<String, dynamic>.from(e.value as Map),
      },
      refused: json['refused'] == true,
    );
  }

  PendingOrder withError(String? error, {bool refused = false}) => PendingOrder(
        id: id,
        customer: customer,
        customerName: customerName,
        deliveryDate: deliveryDate,
        items: items,
        salesPerson: salesPerson,
        savedAt: savedAt,
        isLead: isLead,
        lastError: error,
        commitment: commitment,
        commitmentDue: commitmentDue,
        deliveryMode: deliveryMode,
        sapPending: sapPending,
        refused: refused,
      );

  static List<Map<String, dynamic>> _rows(dynamic v) => (v as List? ?? [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

/// What came of trying to send the drafts.
class SendResult {
  final List<String> sent;
  final List<PendingOrder> failed;
  const SendResult(this.sent, this.failed);

  bool get allSent => failed.isEmpty;
}

class PendingOrders {
  static const _key = 'pendingOrders';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// Every draft this rep is holding, oldest first — the order they were taken
  /// in, which is the order a rep expects to send them in.
  static Future<List<PendingOrder>> all() async {
    try {
      final raw = (await _prefs).getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      final me = Session.I.salesPerson;
      final out = list
          .map(PendingOrder.fromJson)
          .whereType<PendingOrder>()
          .where((o) => me == null || o.salesPerson == me)
          .toList();
      out.sort((a, b) => a.savedAt.compareTo(b.savedAt));
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<int> count() async => (await all()).length;

  /// Counts saves within this run, so two drafts made in the same clock tick
  /// still get different ids.
  static int _seq = 0;

  static Future<PendingOrder> save({
    required String customer,
    required String customerName,
    required String deliveryDate,
    required List<Map<String, dynamic>> items,
    bool isLead = false,
    String? commitment,
    String? commitmentDue,
    String? deliveryMode,
    Map<String, Map<String, dynamic>> sapPending = const {},
  }) async {
    final now = serverNow();
    final existing = await _raw();

    // The id has to be genuinely unique: it is what `remove` matches on, so a
    // collision would delete somebody else's order along with this one. A
    // timestamp alone is not enough — the clock only ticks every millisecond or
    // so on some devices, and two saves can land inside one tick.
    String id;
    do {
      id = 'draft-${now.microsecondsSinceEpoch}-${_seq++}';
    } while (existing.any((o) => o.id == id));

    final draft = PendingOrder(
      id: id,
      customer: customer,
      customerName: customerName,
      deliveryDate: deliveryDate,
      items: items,
      salesPerson: Session.I.salesPerson ?? '',
      savedAt: now,
      isLead: isLead,
      commitment: commitment,
      commitmentDue: commitmentDue,
      deliveryMode: deliveryMode,
      sapPending: sapPending,
    );
    await _replaceAll([...existing, draft]);
    return draft;
  }

  /// The draft's lines with SAP's price on every line that waited for one
  /// ([PendingOrder.sapPending]): the rate per kg, the line rate and the
  /// amount. Throws [OrderRefused] naming the first product SAP has no price
  /// for. Lines that did not wait are copied as they are.
  static List<Map<String, dynamic>> priceFromSap(PendingOrder d, SapRates rates) {
    final out = <Map<String, dynamic>>[];
    for (final item in d.items) {
      final copy = Map<String, dynamic>.from(item);
      final code = '${item['item_code'] ?? ''}';
      final wait = d.sapPending[code];
      if (wait != null) {
        final r = rates[code];
        if (r == null) {
          throw OrderRefused('No price in SAP for ${wait['n'] ?? code}.');
        }
        final factor = (wait['f'] as num?)?.toDouble() ?? 1;
        final qty = (item['qty'] as num?)?.toDouble() ?? 0;
        final lineRate = r.rate * factor;
        copy['rate'] = double.parse(lineRate.toStringAsFixed(4));
        copy['amount'] = double.parse((qty * lineRate).toStringAsFixed(2));
        copy['custom_rate_per_kg'] = r.rate;
      }
      out.add(copy);
    }
    return out;
  }

  /// What the draft came to at the prices on the phone when it was taken, or
  /// null when a line SAP prices had no price then — there is nothing to
  /// compare SAP's price at sending against.
  static double? pricedTotal(PendingOrder d) {
    for (final item in d.items) {
      final code = '${item['item_code'] ?? ''}';
      if (!d.sapPending.containsKey(code)) continue;
      if (((item['rate'] as num?)?.toDouble() ?? 0) <= 0) return null;
    }
    return totalOf(d.items);
  }

  /// Adds the customer's commitment to a held draft and lets it go again by
  /// itself.
  static Future<void> setCommitment(String id, String text, String? due) async {
    final list = await _raw();
    await _replaceAll([
      for (final d in list)
        d.id == id
            ? PendingOrder(
                id: d.id,
                customer: d.customer,
                customerName: d.customerName,
                deliveryDate: d.deliveryDate,
                items: d.items,
                salesPerson: d.salesPerson,
                savedAt: d.savedAt,
                isLead: d.isLead,
                commitment: text,
                commitmentDue: due,
                deliveryMode: d.deliveryMode,
                sapPending: d.sapPending,
              )
            : d
    ]);
  }

  /// What [items] come to: quantity times line rate.
  static double totalOf(List<Map<String, dynamic>> items) => items.fold(
      0.0,
      (sum, i) =>
          sum +
          ((i['qty'] as num?)?.toDouble() ?? 0) *
              ((i['rate'] as num?)?.toDouble() ?? 0));

  static Future<void> remove(String id) async =>
      _replaceAll((await _raw()).where((o) => o.id != id).toList());

  /// Wipes every draft on the handset, not just this rep's. Called on sign-out.
  static Future<void> clear() async => (await _prefs).remove(_key);

  static Future<SendResult>? _inFlight;

  /// Sends the drafts, oldest first.
  ///
  /// [submit] does the real work and returns the order number. A draft that
  /// sends is deleted; one that fails stays put with the reason attached, so
  /// nothing is lost when the signal drops again mid-batch.
  ///
  /// The signal going stops the run: the rest would fail the same way. A
  /// refusal does not — it is that one order the server said no to, kept with
  /// its reason and marked [PendingOrder.refused], and the next is tried.
  ///
  /// [auto] is the home screen sending by itself: refused drafts are left for
  /// the rep, so one the server will not take is not resent every minute.
  ///
  /// One run at a time: the home screen's retry and the rep's Send button
  /// overlapping would send the same order twice.
  static Future<SendResult> sendAll(
      Future<String> Function(PendingOrder draft) submit,
      {String Function(Object error)? describe, bool auto = false}) {
    return _inFlight ??= _sendAll(submit, describe, auto)
        .whenComplete(() => _inFlight = null);
  }

  static Future<SendResult> _sendAll(
      Future<String> Function(PendingOrder draft) submit,
      String Function(Object error)? describe,
      bool auto) async {
    final sent = <String>[];
    final failed = <PendingOrder>[];
    var offline = false;

    for (final draft in await all()) {
      if (offline || (auto && draft.refused)) {
        failed.add(draft);
        continue;
      }
      try {
        sent.add(await submit(draft));
        await remove(draft.id);
      } catch (e) {
        final message = describe != null ? describe(e) : '$e';
        offline = isNetworkFailure(e);
        final kept = draft.withError(message, refused: !offline);
        await _update(kept);
        failed.add(kept);
      }
    }
    return SendResult(sent, failed);
  }

  /// Drafts the home screen would send by itself: not refused.
  static Future<int> autoCount() async =>
      (await all()).where((d) => !d.refused).length;

  // -- storage ---------------------------------------------------------------

  /// Every draft on the handset, including other reps'. Used for writes so a
  /// save never drops somebody else's rows.
  static Future<List<PendingOrder>> _raw() async {
    try {
      final s = (await _prefs).getString(_key);
      if (s == null || s.isEmpty) return [];
      final list = jsonDecode(s);
      if (list is! List) return [];
      return list.map(PendingOrder.fromJson).whereType<PendingOrder>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _update(PendingOrder draft) async => _replaceAll(
      (await _raw()).map((o) => o.id == draft.id ? draft : o).toList());

  static Future<void> _replaceAll(List<PendingOrder> orders) async {
    await (await _prefs)
        .setString(_key, jsonEncode(orders.map((o) => o.toJson()).toList()));
  }
}
