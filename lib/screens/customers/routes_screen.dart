// The rep's own delivery routes.
//
// A route is what production plans a delivery by, so a rep who covers a new
// town needs to be able to name it without waiting on the office. Adding one is
// deliberately trivial; removing one is not, because a route with customers on
// it is load-bearing and Frappe refuses to delete it. That refusal is shown as
// it comes back rather than pre-empted — the app cannot see every doctype that
// might point at a route, so guessing would only be wrong in a different way.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';

class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key});
  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  bool _busy = false;

  /// True once anything changed, so the screen that opened this can reload its
  /// own route list rather than showing one that is a step behind.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _future = Api.getMySalesRoutes();
  }

  void _reload() => setState(() => _future = Api.getMySalesRoutes());

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 5)));

  Future<void> _add() async {
    final rep = Session.I.salesPerson;
    if (rep == null || rep.isEmpty) {
      _snack('No sales person linked to this login.');
      return;
    }

    final ctrl = TextEditingController();
    final area = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a route'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Route',
              // The rep's name is shown as a fixed prefix rather than typed.
              // Every route in the system is named "Rep - Area", and a rep who
              // has to remember that will eventually not — leaving one route
              // sorted away from all their others.
              prefixText: '$rep - ',
              prefixStyle: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.black87),
              hintText: 'Thrissur',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 8),
          const Text(
              'Type the area only — your name is added automatically so your '
              'routes stay together in every list.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Add')),
        ],
      ),
    );

    if (area == null || area.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final name = await Api.createSalesRoute(area);
      _changed = true;
      _snack('Added $name ✓');
      _reload();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> route) async {
    final name = '${route['name']}';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this route?'),
        content: Text(
            '$name will be removed.\n\nIf any customer, lead or site is still '
            'on this route, it cannot be deleted — move them to another route '
            'first.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;

    setState(() => _busy = true);
    try {
      await Api.deleteSalesRoute(name);
      _changed = true;
      _snack('Deleted $name ✓');
      _reload();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('My Routes'), actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ]),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.add_road),
          label: const Text('Add route'),
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(humanError(snap.error))));
            }
            final routes = snap.data ?? [];
            if (routes.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.alt_route, size: 56, color: Colors.black26),
                      SizedBox(height: 16),
                      Text('No routes yet',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      SizedBox(height: 8),
                      Text(
                        'Production plans every delivery by route, so a '
                        'customer without one cannot be scheduled. Add the '
                        'areas you cover.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: routes.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = routes[i];
                final active = (r['is_active'] ?? 0) == 1;
                final day = '${r['visit_day'] ?? ''}';
                return ListTile(
                  leading: Icon(Icons.alt_route,
                      color: active ? const Color(0xFFF46A21) : Colors.black26),
                  title: Text('${r['route_name'] ?? r['name']}'),
                  subtitle: Text([
                    if (!active) 'Inactive',
                    if (day.isNotEmpty && day != 'null') 'Visit day: $day',
                  ].join('  ·  ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.redAccent),
                    onPressed: _busy ? null : () => _delete(r),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
