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
// office server reads the flags every 5 seconds and runs whichever are up
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
// `syncsForSession` in core/sync_scope.dart decides, and the credit bar asks
// the same function. Orders: everybody. Stock (with the items and the two
// weight UDFs): everybody except a login of another unit. Credit: the Manna
// Treads side and the GM. Until 25 September 2026 stock and credit were for
// the Treads side only (`Session.isTreadsUnit`), which left the GM unable to
// refresh the credit he approves on.
//
// The dashboard's twin is `client/src/components/layout/SyncAllButton.tsx`.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/sync_scope.dart';
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

  /// The name of the route on top, where it has one.
  static String? _topRoute;

  /// Routes that carry Sync in their own header, so the floating button
  /// would only be a second copy of it.
  static const Set<String> hostsOwnSync = {kManagerWorkspaceRoute};
}

/// Was the tabbed manager workspace's route name; that workspace was removed
/// on 11 Oct 2026 and nothing carries this name now.
const String kManagerWorkspaceRoute = 'manager-workspace';

class _RouteTick extends NavigatorObserver {
  // Only pages count as "on top". A dialog or a sheet over the workspace must
  // not bring the floating button back underneath it.
  void _top(Route<dynamic>? r) {
    if (r is PageRoute) SapSyncAll._topRoute = r.settings.name;
    SapSyncAll._routes.value++;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _top(newRoute);
  @override
  // Removal is how pushAndRemoveUntil clears what lay underneath, so the
  // route on top has not changed.
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      SapSyncAll._routes.value++;
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
          builder: (context, _, __) => Session.I.hasToken &&
                  !SapSyncAll.hostsOwnSync.contains(SapSyncAll._topRoute)
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

/// The watcher looks every 5 seconds and a run takes about 30, so a flag
/// still up after four minutes means the office side is not picking anything up.
const Duration _giveUpAfter = Duration(minutes: 4);

String _list(Iterable<_Kind> kinds) {
  final names = kinds.map((k) => _label[k]!).toList();
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// The sync itself, shared by every button that starts one.
///
/// There are two: the floating one above the Navigator, and the one in the
/// manager workspace's header (11 Oct 2026). Holding the run here means a
/// press on either shows as running on both, and a second press while one is
/// in flight does nothing rather than raising the flags twice.
class SapSyncEngine extends ChangeNotifier {
  SapSyncEngine._();
  static final SapSyncEngine I = SapSyncEngine._();

  bool _working = false;
  bool get working => _working;
  Timer? _timer;

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

  void _set(bool v) {
    _working = v;
    notifyListeners();
  }

  Future<void> press() async {
    if (_working) return;
    _set(true);
    final scope = syncsForSession(Session.I);
    final kinds = [
      _Kind.orders,
      if (scope.contains(SyncKind.stock)) _Kind.stock,
      if (scope.contains(SyncKind.credit)) _Kind.credit,
    ];

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
    _say('Syncing ${_list(asked)} with SAP…');
    _watch(asked, DateTime.now(), failed);
  }

  void _watch(List<_Kind> pending, DateTime since, List<_Kind> failed) {
    _timer?.cancel();
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
      if (still.isEmpty) {
        _finish(nowFailed);
        return;
      }
      if (DateTime.now().difference(since) > _giveUpAfter) {
        _set(false);
        _say('Still waiting on the office server for ${_list(still)}. '
            'It will run when the server picks it up.');
        return;
      }
      _watch(still, since, nowFailed);
    });
  }

  void _finish(List<_Kind> failed) {
    _set(false);
    SapSyncAll.epoch.value++;
    _say(failed.isEmpty
        ? 'Synced with SAP.'
        : 'Synced, but ${_list(failed)} did not go through. Try again in a minute.');
  }
}

/// When the order sync last finished, as "Synced today 18:52". Blank when it
/// cannot be read — a freshness line that guesses is worse than none.
Future<String> lastSyncLabel() async {
  try {
    final s = await Api.orderSyncStatus();
    final raw = '${s['last_sync_at'] ?? ''}';
    final at = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (at == null) return '';
    final now = DateTime.now();
    final hm =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Synced today $hm';
    if (diff == 1) return 'Synced yesterday $hm';
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Synced ${at.day} ${m[at.month - 1]} $hm';
  } catch (_) {
    return '';
  }
}

class SyncAllButton extends StatelessWidget {
  const SyncAllButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SapSyncEngine.I,
      builder: (context, _) {
        final working = SapSyncEngine.I.working;
        return Material(
          color: const Color(0xFF3F3F3F),
          shape: const CircleBorder(),
          elevation: 3,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: working ? null : SapSyncEngine.I.press,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: working
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.sync, color: Colors.white, semanticLabel: 'Sync with SAP'),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The Sync control for an AppBar: an icon and a word, spinning while a run
/// is in flight.
class SyncAppBarButton extends StatelessWidget {
  const SyncAppBarButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SapSyncEngine.I,
      builder: (context, _) {
        final working = SapSyncEngine.I.working;
        return TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          onPressed: working ? null : SapSyncEngine.I.press,
          icon: working
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.sync, size: 20),
          label: Text(working ? 'Syncing' : 'Sync',
              style: const TextStyle(color: Colors.white)),
        );
      },
    );
  }
}
