// Orders composed with no signal, held until there is one.
//
// A draft here is explicitly *not* an order. Nothing is reserved, no customer
// has been promised anything, and the rep is told so in those words. That
// honesty is the whole design: minimum stock is only really held once the
// server says so, and pretending otherwise at the counter is how a customer
// gets promised rolls that another rep has already taken.
//
// So the deal offered to a rep with no bars is "type it now, send it when you
// have signal, and find out then whether the stock is still there" — which
// beats both losing the order and being lied to about it.
//
// Drafts belong to the rep who typed them and are cleared on sign-out, so a
// shared handset never carries one person's orders into another's session.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';

class PendingOrder {
  /// Local id. Not an order number — this has never reached the server.
  final String id;
  final String customer;
  final String customerName;
  final String deliveryDate;
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> reservations;
  final String salesPerson;
  final DateTime savedAt;

  /// True when the party is a lead rather than a customer. Decides which
  /// order the draft becomes when it is finally sent.
  final bool isLead;

  /// Why the last send attempt failed, in the words the rep was shown.
  final String? lastError;

  const PendingOrder({
    required this.id,
    required this.customer,
    required this.customerName,
    required this.deliveryDate,
    required this.items,
    required this.reservations,
    required this.salesPerson,
    required this.savedAt,
    this.isLead = false,
    this.lastError,
  });

  double get total => items.fold(
      0.0,
      (sum, i) =>
          sum +
          ((i['qty'] as num?)?.toDouble() ?? 0) *
              ((i['rate'] as num?)?.toDouble() ?? 0));

  /// True when this draft asks for minimum stock — the reason it cannot be
  /// treated as confirmed until the server has seen it.
  bool get needsStock => reservations.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'customer': customer,
        'customer_name': customerName,
        'delivery_date': deliveryDate,
        'items': items,
        'reservations': reservations,
        'sales_person': salesPerson,
        'saved_at': savedAt.toIso8601String(),
        if (isLead) 'is_lead': true,
        if (lastError != null) 'last_error': lastError,
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
      reservations: _rows(json['reservations']),
      salesPerson: '${json['sales_person'] ?? ''}',
      savedAt: DateTime.tryParse('${json['saved_at'] ?? ''}') ?? serverNow(),
      isLead: json['is_lead'] == true,
      lastError: json['last_error'] as String?,
    );
  }

  PendingOrder withError(String? error) => PendingOrder(
        id: id,
        customer: customer,
        customerName: customerName,
        deliveryDate: deliveryDate,
        items: items,
        reservations: reservations,
        salesPerson: salesPerson,
        savedAt: savedAt,
        isLead: isLead,
        lastError: error,
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
    required List<Map<String, dynamic>> reservations,
    bool isLead = false,
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
      reservations: reservations,
      salesPerson: Session.I.salesPerson ?? '',
      savedAt: now,
      isLead: isLead,
    );
    await _replaceAll([...existing, draft]);
    return draft;
  }

  static Future<void> remove(String id) async =>
      _replaceAll((await _raw()).where((o) => o.id != id).toList());

  /// Wipes every draft on the handset, not just this rep's. Called on sign-out.
  static Future<void> clear() async => (await _prefs).remove(_key);

  /// Sends the drafts, oldest first.
  ///
  /// [submit] does the real work and returns the order number. A draft that
  /// sends is deleted; one that fails stays put with the reason attached, so
  /// nothing is lost when the signal drops again mid-batch.
  ///
  /// Sending stops at the first failure. If the network has gone again, the
  /// rest will fail the same way, and burning through ten drafts to collect ten
  /// identical errors only delays telling the rep.
  static Future<SendResult> sendAll(
      Future<String> Function(PendingOrder draft) submit,
      {String Function(Object error)? describe}) async {
    final sent = <String>[];
    final failed = <PendingOrder>[];

    for (final draft in await all()) {
      if (failed.isNotEmpty) {
        failed.add(draft);
        continue;
      }
      try {
        sent.add(await submit(draft));
        await remove(draft.id);
      } catch (e) {
        final message = describe != null ? describe(e) : '$e';
        await _update(draft.withError(message));
        failed.add(draft.withError(message));
      }
    }
    return SendResult(sent, failed);
  }

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
