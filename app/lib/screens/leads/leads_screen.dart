import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/leads/add_lead_screen.dart';
import 'package:manna_field_sales/screens/leads/lead_detail_screen.dart';
import 'package:manna_field_sales/screens/customers/routes_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class LeadsScreen extends StatefulWidget {
  const LeadsScreen({super.key});
  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends State<LeadsScreen> {
  static const String _allRoutes = '__all__';

  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';
  String _route = _allRoutes;

  /// Routes the rep actually has leads on, taken from the loaded list rather
  /// than from a route fetch — so the dropdown never offers one that would
  /// come back empty. Same rule as the customer list.
  List<String> _routes = [];

  @override
  void initState() {
    super.initState();
    _future = Api.getLeads();
  }

  void _reload() => setState(() { _future = Api.getLeads(); });

  /// Rebuilt from each load. Leads with no route are reachable through the
  /// "No route set" entry rather than being filtered into invisibility — an
  /// unrouted lead is exactly the one a rep needs to find and fix.
  void _rebuildRoutes(List<Map<String, dynamic>> all) {
    final found = all
        .map((c) => '${c['custom_sales_route'] ?? ''}')
        .where((t) => t.isNotEmpty && t != 'null')
        .toSet()
        .toList()
      ..sort();
    if (found.length != _routes.length ||
        !found.every(_routes.contains)) {
      // Set outside build via a post-frame callback would be heavier than this
      // is worth; the list is small and only changes on reload.
      _routes = found;
    }
  }

  bool _hasRoute(Map<String, dynamic> r) {
    final v = '${r['custom_sales_route'] ?? ''}';
    return v.isNotEmpty && v != 'null';
  }

  bool _match(Map<String, dynamic> r) {
    if (_route == _noRoute) {
      if (_hasRoute(r)) return false;
    } else if (_route != _allRoutes &&
        '${r['custom_sales_route'] ?? ''}' != _route) {
      return false;
    }
    if (_q.isEmpty) return true;
    final hay = [
      r['lead_name'],
      r['company_name'],
      r['mobile_no'],
      r['custom_sales_route'],
      r['status']
    ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_q.toLowerCase());
  }

  static const String _noRoute = '__none__';

  Widget _routeFilter() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _route,
              isExpanded: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.alt_route),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                    value: _allRoutes, child: Text('All routes')),
                const DropdownMenuItem(
                    value: _noRoute, child: Text('No route set')),
                for (final t in _routes)
                  DropdownMenuItem(value: t, child: Text(t)),
              ],
              onChanged: (v) => setState(() => _route = v ?? _allRoutes),
            ),
          ),
          IconButton(
            tooltip: 'Manage routes',
            icon: const Icon(Icons.edit_road),
            onPressed: () async {
              final changed = await Navigator.push<bool>(context,
                  MaterialPageRoute(builder: (_) => const RoutesScreen()));
              if (changed == true) _reload();
            },
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Leads'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add Lead'),
        onPressed: () async {
          final created = await Navigator.push<bool>(context,
              MaterialPageRoute(builder: (_) => const AddLeadScreen()));
          if (created == true) _reload();
        },
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search leads…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
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
              final all = snap.data!;
              _rebuildRoutes(all);
              final rows = all.where(_match).toList();
              return Column(children: [
                OfflineBanner.forKey(CacheKeys.leads),
                if (all.isNotEmpty) _routeFilter(),
                Expanded(
                  child: all.isEmpty
                      ? const Center(
                          child: Text('No leads yet. Tap “Add Lead”.'))
                      : rows.isEmpty
                          ? Center(
                              child: Text(_route == _noRoute
                                  ? 'Every lead has a route ✓'
                                  : 'No matches.'))
                          : _leadList(rows),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  Widget _leadList(List<Map<String, dynamic>> rows) => ListView.separated(
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final r = rows[i];
          return ListTile(
            leading: const Icon(Icons.emoji_objects_outlined),
            title: Text(r['lead_name'] ?? r['name']),
            // The sales route, not the territory — the same leftover that left
            // the customer card blank after routes moved to their own doctype.
            subtitle: Text([
              r['company_name'],
              r['custom_sales_route'],
              r['mobile_no']
            ]
                .where((x) =>
                    x != null && '$x'.isNotEmpty && '$x' != 'null')
                .join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(ctx,
                    MaterialPageRoute(builder: (_) => LeadDetailScreen(lead: r)))
                .then((_) => _reload()),
          );
        },
      );
}

