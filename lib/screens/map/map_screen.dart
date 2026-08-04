import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/map_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _customers = [];

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
      final list = await Api.getCustomers();
      _customers = list
          .where((c) => isMappableLatLng(
              _num(c['custom_latitude']), _num(c['custom_longitude'])))
          .toList();
    } catch (e) {
      _error = humanError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  void _showCustomer(Map<String, dynamic> c, double lat, double lng) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.location_pin, color: Colors.red),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${c['customer_name'] ?? c['name']}',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 4),
            Text([c['customer_group'], c['territory']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' · ')),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                navigateTo(lat, lng);
              },
              icon: const Icon(Icons.directions),
              label: const Text('Navigate'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.location_pin, color: Colors.red, size: 16),
        const SizedBox(width: 4),
        Text('Customer (${_customers.length})',
            style: const TextStyle(fontSize: 11)),
      ]),
    );
  }

  Widget _map() {
    if (_customers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No customers have coordinates yet.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final latlngs = <LatLng>[];
    final markers = <Marker>[];
    for (final c in _customers) {
      final lat = _num(c['custom_latitude']);
      final lng = _num(c['custom_longitude']);
      latlngs.add(LatLng(lat, lng));
      markers.add(Marker(
        point: LatLng(lat, lng),
        width: 44,
        height: 44,
        child: GestureDetector(
          onTap: () => _showCustomer(c, lat, lng),
          child: const Icon(Icons.location_pin, color: Colors.red, size: 44),
        ),
      ));
    }
    final cz = mapCenterZoom(latlngs);
    return FlutterMap(
      options: MapOptions(initialCenter: cz.center, initialZoom: cz.zoom),
      children: [
        TileLayer(
          urlTemplate: mapTileUrl(),
          userAgentPackageName: 'com.manna.fieldsales',
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Map'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_error != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              Expanded(child: _map()),
              _legend(),
            ]),
    );
  }
}

// -------------------- ATTENDANCE --------------------
