// Sync — one button on every screen.
//
// From 24 September 2026 nothing syncs with SAP on a timer. Orders, stock and
// credit limits move only when somebody presses this, or approves an order
// (which raises the order flag by itself — see `Api.approveSalesOrderPO`).
//
// WHAT A PRESS DOES
//
// Frappe Cloud has no route to the SAP LAN, so nothing here talks to SAP. It
// raises one flag per sync on that sync's ERPNext Single; a watcher on the
// office server reads the flags every 15 seconds and runs whichever are up
// (`sap-order-sync/Invoke-FlagWatch.ps1`). So there is nothing to await — the
// button polls the statuses until they settle, then says so.
//
// WHY IT SITS ABOVE THE NAVIGATOR
//
// Fifty screens each build their own AppBar and there is no shared scaffold,
// so the button is placed once, in `MaterialApp.builder`, and appears on every
// route without touching any of them. Being above the Navigator it has no
// Overlay, which is why it uses no Tooltip, and it shows its message through
// [SapSyncAll.messengerKey] rather than `ScaffoldMessenger.of`.
//
// It sits bottom-left, raised clear of a bottom navigation bar: six screens
// have a floating action button, all at the default bottom-right.
//
// WHY IT DOES NOT RELOAD THE SCREEN
//
// Flutter has no way to rebuild "whatever route is showing" from here, and
// popping to the home screen would throw away where the rep was. Every read in
// the app is network-first (`OfflineCache.read`), so the next time a screen
// loads it has SAP's latest. [SapSyncAll.epoch] is bumped when a sync settles
// so a screen that wants to reload itself can listen for it.
//
// WHO RAISES WHICH FLAG
//
// The order sync: everybody. Stock and credit limits: the Manna Treads side
// only (`Session.isTreadsUnit`) — the same rule as the credit bar and the
// Server Scripts, since both syncs write into Manna Treads' books.
//
// The dashboard's twin is `client/src/components/layout/SyncAllButton.tsx`.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

/// App-wide hooks for the Sync button.
class SapSyncAll {
  SapSyncAll._();

  /// Given to `MaterialApp.scaffoldMessengerKey`, so the button — which sits
  /// above the Navigator — can still show a message.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Bumped every time a sync settles. A screen can listen and reload.
  static final ValueNotifier<int> epoch = ValueNotifier<int>(0);

  /// Bumped on every navigation, so the button notices a login or a logout
  /// without polling.
  static final ValueNotifier<int> _routes = ValueNotifier<int>(0);

  /// Given to `MaterialApp.navigatorObservers`.
  static final NavigatorObserver observer = _RouteTick();
}

class _RouteTick extends NavigatorObserver {
  void _bump() => SapSyncAll._routes.value++;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _bump();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _bump();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _bump();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _bump();
}

/// Put in `MaterialApp.builder` around the app's child.
class SyncAllOverlay extends StatelessWidget {
  final Widget child;
  const SyncAllOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Stack(
      children: [
        child,
        ValueListenableBuilder<int>(
          valueListenable: SapSyncAll._routes,
          builder: (context, _, __) => Session.I.hasToken
              ? Positioned(left: 12, bottom: 84 + bottom, child: const SyncAllButton())
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

enum _Kind { orders, stock, credit }

const Map<_Kind, String> _label = {
  _Kind.orders: 'orders',
  _Kind.stock: 'stock',
  _Kind.credit: 'credit limits',
};

/// Statuses meaning a run is waiting or in flight.
const Set<String> _busy = {'Queued', 'Running'};

const Duration _pollEvery = Duration(seconds: 4);

/// The watcher looks every 15 seconds and a run takes about 30, so a flag
/// still up after four minutes means the office side is not picking anything up.
const Duration _giveUpAfter = Duration(minutes: 4);

String _list(Iterable<_Kind> kinds) {
  final names = kinds.map((k) => _label[k]!).toList();
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

class SyncAllButton extends StatefulWidget {
  const SyncAllButton({super.key});
  @override
  State<SyncAllButton> createState() => _SyncAllButtonState();
}

class _SyncAllButtonState extends State<SyncAllButton> {
  bool _working = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _ask(_Kind k) {
    if (k == _Kind.orders) return Api.requestOrderSync();
    if (k == _Kind.stock) return Api.requestStockSync();
    return Api.requestSapSync();
  }

  /// (busy, failed) for one sync.
  Future<(bool, bool)> _read(_Kind k) async {
    if (k == _Kind.orders) {
      // The order Single has no Queued status: waiting is sync_requested = 1.
      final s = await Api.orderSyncStatus();
      final status = '${s['status'] ?? ''}';
      final queued = '${s['sync_requested'] ?? 0}' == '1';
      return (queued || status == 'Running', status == 'Failed');
    }
    final s = k == _Kind.stock ? await Api.stockSyncStatus() : await Api.sapSyncStatus();
    final status = '${s['status'] ?? ''}';
    return (_busy.contains(status), status == 'Failed');
  }

  void _say(String text) {
    SapSyncAll.messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _press() async {
    if (_working) return;
    setState(() => _working = true);
    final kinds = Session.I.isTreadsUnit
        ? const [_Kind.orders, _Kind.stock, _Kind.credit]
        : const [_Kind.orders];

    final asked = <_Kind>[];
    final failed = <_Kind>[];
    for (final k in kinds) {
      try {
        await _ask(k);
        asked.add(k);
      } catch (_) {
        failed.add(k);
      }
    }
    if (asked.isEmpty) {
      _finish(failed);
      return;
    }
    _say('Asked SAP for the latest ${_list(asked)}…');
    _watch(asked, DateTime.now(), failed);
  }

  void _watch(List<_Kind> pending, DateTime since, List<_Kind> failed) {
    _timer = Timer(_pollEvery, () async {
      final still = <_Kind>[];
      final nowFailed = [...failed];
      for (final k in pending) {
        try {
          final (busy, didFail) = await _read(k);
          if (busy) {
            still.add(k);
          } else if (didFail) {
            nowFailed.add(k);
          }
        } catch (_) {
          // Unreadable is not "still going": stop waiting on it and say so.
          nowFailed.add(k);
        }
      }
      if (!mounted) return;
      if (still.isEmpty) {
        _finish(nowFailed);
        return;
      }
      if (DateTime.now().difference(since) > _giveUpAfter) {
        setState(() => _working = false);
        _say('Still waiting on the office server for ${_list(still)}. '
            'Your request is saved and will run when it picks it up.');
        return;
      }
      _watch(still, since, nowFailed);
    });
  }

  void _finish(List<_Kind> failed) {
    if (!mounted) return;
    setState(() => _working = false);
    SapSyncAll.epoch.value++;
    _say(failed.isEmpty
        ? 'Synced with SAP. Reopen a screen to see the latest.'
        : 'Synced, but ${_list(failed)} did not go through. Try again in a minute.');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF3F3F3F),
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _working ? null : _press,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: _working
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.sync, color: Colors.white, semanticLabel: 'Sync with SAP'),
          ),
        ),
      ),
    );
  }
}
