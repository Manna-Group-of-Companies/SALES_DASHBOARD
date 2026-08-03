import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/screens/customers/customer_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/map_service.dart';

class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});
  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  static const String _allRoutes = '__all__';

  List<Map<String, dynamic>> _all = [];
  List<Map<String, dynamic>> _reps = [];
  // Routes (Territories) the rep actually has customers on — taken from the
  // loaded list rather than a Territory fetch, so the dropdown never offers a
  // route that would come back empty.
  List<String> _routes = [];
  bool _loading = true;
  String? _error;

  String _q = '';
  String _route = _allRoutes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Future.wait([Api.getCustomers(), Api.getSalesPersons()]);
      final all = r[0];
      final routes = all
          .map((c) => (c['custom_sales_route'] ?? '').toString())
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (!mounted) return;
      setState(() {
        _all = all;
        _reps = r[1];
        _routes = routes;
        if (_route != _allRoutes && !routes.contains(_route)) {
          _route = _allRoutes;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  bool _match(Map<String, dynamic> c) {
    if (_route != _allRoutes && '${c['custom_sales_route'] ?? ''}' != _route) {
      return false;
    }
    if (_q.isEmpty) return true;
    final hay = [c['customer_name'], c['name'], c['customer_group'], c['custom_sales_route']]
        .map((e) => (e ?? '').toString().toLowerCase())
        .join(' ');
    return hay.contains(_q.toLowerCase());
  }

  static double _num(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search customers…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _route,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.alt_route, size: 18),
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: _allRoutes, child: Text('All routes')),
            ..._routes.map((r) => DropdownMenuItem(value: r, child: Text(r))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _route = v);
          },
        ),
      ]),
    );
  }

  // Where the shop location sits: captured and verified, waiting on the
  // manager, rejected, or never captured at all.
  ({Color color, IconData icon, String label}) _locationBadge(
      Map<String, dynamic> c) {
    final s = (c['custom_location_status'] ?? 'Not Captured').toString();
    if (s == 'Verified') {
      return (color: Colors.green, icon: Icons.verified, label: 'Verified');
    }
    if (s == 'Pending Verification') {
      return (
        color: Colors.orange,
        icon: Icons.hourglass_top,
        label: 'Pending verification'
      );
    }
    if (s == 'Rejected') {
      return (color: Colors.red, icon: Icons.cancel, label: 'Rejected');
    }
    return (
      color: Colors.grey,
      icon: Icons.location_off,
      label: 'No location'
    );
  }

  void _open(Map<String, dynamic> c) => Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => CustomerDetailScreen(customer: c, reps: _reps)));

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No dialler available.')));
      }
    }
  }

  /// Quick look at one customer without leaving the list — the fields a rep
  /// checks while working down a route, plus call/navigate shortcuts.
  void _showDetails(Map<String, dynamic> c) {
    final badge = _locationBadge(c);
    final lat = _num(c['custom_latitude']);
    final lng = _num(c['custom_longitude']);
    final mappable = isMappableLatLng(lat, lng);
    final phone = '${c['custom_phone'] ?? ''}'.trim();
    final bal = _num(c['custom_outstanding_balance']);
    final lim = _num(c['custom_credit_limit']);

    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 110,
                child: Text(label,
                    style:
                        const TextStyle(fontSize: 13, color: Colors.black54))),
            Expanded(
                child: Text(value,
                    style: TextStyle(
                        fontSize: 14,
                        color: color,
                        fontWeight:
                            color == null ? FontWeight.normal : FontWeight.bold))),
          ]),
        );

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${c['customer_name'] ?? c['name']}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                row('Route',
                    '${c['custom_sales_route'] ?? ''}'.isEmpty ? '—' : '${c['territory']}'),
                row(
                    'Group',
                    '${c['customer_group'] ?? ''}'.isEmpty
                        ? '—'
                        : '${c['customer_group']}'),
                row('Phone', phone.isEmpty ? '—' : phone),
                row('Customer ID', '${c['name']}'),
                row('Outstanding', '₹${bal.toStringAsFixed(0)}',
                    color: bal > 0 ? Colors.red : null),
                row('Credit limit', lim > 0 ? '₹${lim.toStringAsFixed(0)}' : '—'),
                row('Location', badge.label, color: badge.color),
                if (mappable)
                  row('Coordinates',
                      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: phone.isEmpty
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _call(phone);
                            },
                      icon: const Icon(Icons.call),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: mappable
                          ? () {
                              Navigator.pop(sheet);
                              navigateTo(lat, lng);
                            }
                          : null,
                      icon: const Icon(Icons.directions),
                      label: const Text('Navigate'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheet);
                    _open(c);
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open full details'),
                ),
              ]),
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> c) {
    final badge = _locationBadge(c);
    final lat = _num(c['custom_latitude']);
    final lng = _num(c['custom_longitude']);
    final mappable = isMappableLatLng(lat, lng);
    final bal = _num(c['custom_outstanding_balance']);
    final sub = [c['customer_group'], c['custom_sales_route']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(' · ');

    return ListTile(
      title: Text(c['customer_name'] ?? c['name']),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (sub.isNotEmpty) Text(sub),
        const SizedBox(height: 2),
        Row(children: [
          Icon(badge.icon, size: 14, color: badge.color),
          const SizedBox(width: 4),
          Text(badge.label,
              style: TextStyle(fontSize: 12, color: badge.color)),
          if (mappable) ...[
            const SizedBox(width: 6),
            Expanded(
              child: Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.black45)),
            ),
          ],
        ]),
      ]),
      isThreeLine: sub.isNotEmpty,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (bal > 0)
          Text('₹${bal.toStringAsFixed(0)}',
              style: const TextStyle(
                  color: Colors.red, fontWeight: FontWeight.bold)),
        IconButton(
          tooltip: 'Details',
          icon: const Icon(Icons.info_outline),
          color: Colors.blueGrey,
          onPressed: () => _showDetails(c),
        ),
      ]),
      onTap: () => _open(c),
      onLongPress: () => _showDetails(c),
    );
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(20), child: Text('Error: $_error')));
    }
    if (_all.isEmpty) return const Center(child: Text('No customers found.'));
    final customers = _all.where(_match).toList();
    if (customers.isEmpty) {
      return Center(
          child: Text(_route == _allRoutes
              ? 'No matches.'
              : 'No matches on $_route.'));
    }
    return ListView.separated(
      itemCount: customers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _tile(customers[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _loading ? 0 : _all.where(_match).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Customers'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
      body: Column(children: [
        _filters(),
        if (!_loading && _error == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  _route == _allRoutes
                      ? '$shown customers'
                      : '$shown on $_route',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          ),
        Expanded(child: _list()),
      ]),
    );
  }
}
