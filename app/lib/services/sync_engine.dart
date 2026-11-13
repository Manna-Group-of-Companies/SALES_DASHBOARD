// Sends what the phone is holding, by itself, from wherever the rep is in the
// app (13 Nov 2026).
//
// The queues — the outbox, punches, route points and orders — used to be sent
// from the home screen: on opening it, on resume, and once a minute while it
// was alive. A rep who reached signal on any other screen waited for the next
// minute or for the home screen; a manager whose app opened on their own
// workspace waited for nothing at all. The user: "Once the net comes back it
// should send by itself from the app."
//
// So this lives beside the app, not inside a screen. It sends:
//   - the moment Android reports a network after none (`NetState.onBack`);
//   - whenever the app comes back to the front;
//   - once a minute while anything is waiting, because a Wi-Fi with no
//     internet behind it, or one bar of signal, reports "connected" without
//     anything getting through;
//   - when the app starts, so what was saved before a restart goes too.
//
// THE ORDER THINGS GO IN
// The outbox first: a lead or a trip made with no signal has to exist before
// the visit punched at it, the route points drawn on it, or the order taken
// against it. Then punches, route points and orders, then the outbox once
// more for anything queued against what those created.
//
// WHAT THE REP HEARS
// Nothing while it works — the user asked that the app not show the network
// at all. When the server refuses something, the rep is told once, then and
// there, and the item stays on the phone with the reason (Waiting to Send,
// Unsent Orders, Unsent Punches) until they send it again or discard it.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_bus.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/net_cache.dart';
import 'package:manna_field_sales/services/outbox.dart';
import 'package:manna_field_sales/services/pending_orders.dart';
import 'package:manna_field_sales/services/pending_punches.dart';
import 'package:manna_field_sales/services/trip_points.dart';
import 'package:manna_field_sales/widgets/sync_all_button.dart';

class SyncEngine with WidgetsBindingObserver {
  SyncEngine._();
  static final SyncEngine I = SyncEngine._();

  static const Duration retryEvery = Duration(minutes: 1);

  bool _started = false;
  Future<void>? _inFlight;

  /// Starts listening. Safe to call more than once; called when a sign-in is
  /// in hand, whether confirmed by the server or restored with no signal.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    // A kept order goes at SAP's price on the day it is sent (the user, 13 Nov
    // 2026); the rep hears when that differs from what they quoted.
    Api.onRepriced = (customer, before, after) => _say(
        "Order for $customer sent at SAP's price now: "
        '₹${before.toStringAsFixed(2)} → ₹${after.toStringAsFixed(2)}.');
    unawaited(NetState.start());
    NetState.onBack(() {
      unawaited(kick());
      unawaited(Api.prewarm(force: true));
    });
    Timer.periodic(retryEvery, (_) => unawaited(kick()));
    unawaited(kick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(kick());
  }

  /// Sends if anything is waiting. Cheap when nothing is.
  Future<void> kick() async {
    if (!_signedIn) return;
    if (await waiting() > 0) await sendNow();
    // Fills the copies screens fall back on; throttled inside.
    unawaited(Api.prewarm());
  }

  bool get _signedIn => Session.I.email.isNotEmpty;

  /// How many things are waiting to go by themselves.
  static Future<int> waiting() async =>
      await Outbox.autoCount() +
      await PendingPunches.count() +
      await PendingOrders.autoCount() +
      await TripPoints.count();

  /// One pass over every queue, in the order above. Joins a pass already
  /// running rather than starting a second.
  Future<void> sendNow() => _inFlight ??=
      _send().whenComplete(() => _inFlight = null);

  Future<void> _send() async {
    if (!_signedIn) return;
    if (Session.I.offlineStart && !await Api.recoverAfterOfflineStart()) {
      return;
    }
    var any = false;
    try {
      any |= await _outbox();
      final punches =
          await PendingPunches.flush(Api.sendPendingPunch, describe: humanError);
      any |= punches.sent > 0;
      any |= await TripPoints.flush() > 0;
      any |= await _orders();
      any |= await _outbox();
    } catch (_) {
      // One queue failing in a way it did not expect must not stop the
      // next attempt; every queue keeps its own items.
    }
    if (any) AppBus.I.bump();
  }

  Future<bool> _outbox() async {
    if (await Outbox.autoCount() == 0) return false;
    final r = await Outbox.flush(Api.sendOutboxItem,
        describe: humanError, auto: true);
    for (final i in r.failed) {
      // Told once: an item already refused before this pass is skipped by an
      // automatic send and comes back in [failed] untouched.
      if (i.refused && i.lastError != null && !_told.contains(i.id)) {
        _told.add(i.id);
        _say('Not sent: ${i.label}. ${i.lastError}');
      }
    }
    return r.sent > 0;
  }

  Future<bool> _orders() async {
    if (await PendingOrders.autoCount() == 0) return false;
    final r = await PendingOrders.sendAll(Api.sendPendingOrder,
        describe: humanError, auto: true);
    for (final d in r.failed) {
      if (d.refused && d.lastError != null && !_told.contains(d.id)) {
        _told.add(d.id);
        _say('Order for ${d.customerName} not sent. ${d.lastError}');
      }
    }
    return r.sent.isNotEmpty;
  }

  final Set<String> _told = {};

  void _say(String text) {
    SapSyncAll.messengerKey.currentState?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(text),
    ));
  }
}
