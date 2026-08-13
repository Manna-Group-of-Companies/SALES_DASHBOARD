import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/map_service.dart';

class _MapPoint {
  final double lat;
  final double lng;
  final String kind;
  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  _MapPoint({
    required this.lat,
    required this.lng,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
  });
}

class DayMapScreen extends StatefulWidget {
  const DayMapScreen({super.key});
  @override
  State<DayMapScreen> createState() => _DayMapScreenState();
}

class _DayMapScreenState extends State<DayMapScreen> {
  DateTime _date = DateTime.now();
  String? _rep;
  List<Map<String, dynamic>> _reps = [];
  bool _loading = false;
  String? _error;
  List<_MapPoint> _points = [];

  // Route (Territory) overlay — pick one and its customers show on the map.
  static const String _allRoutes = '__all__';
  List<String> _routes = [];
  String _route = _allRoutes;
  bool _loadingRoute = false;
  List<_MapPoint> _routePoints = [];

  // Standing layers, moved here from My Map: my recent customer and lead visits.
  static const int _visitDays = 30;
  bool _showVisits = false;
  bool _showLeadVisits = false;
  bool _loadingLayers = false;
  bool _layersLoaded = false;
  List<_MapPoint> _myVisitPoints = [];
  List<_MapPoint> _myLeadVisitPoints = [];

  // Lead overlay — every lead whose location has been captured, narrowed to the
  // picked route when there is one.
  bool _showLeads = false;
  bool _loadingLeads = false;
  List<_MapPoint> _leadPoints = [];

  bool get _canPick =>
      Session.I.isManager || Session.I.isGM || Session.I.isHR;

  @override
  void initState() {
    super.initState();
    _rep = Session.I.salesPerson;
    _init();
  }

  Future<void> _init() async {
    if (_canPick) {
      try {
        _reps = await Api.getPickableReps();
        if ((_rep == null || _rep!.isEmpty) && _reps.isNotEmpty) {
          _rep = _reps.first['name'] as String;
        }
        if (mounted) setState(() {});
      } catch (e) {
        if (mounted) setState(() => _error = humanError(e));
      }
    }
    _loadRoutes();
    if (_rep != null && _rep!.isNotEmpty) _load();
  }

  // Scoped to whoever is being viewed, so a manager looking at a UAE rep is
  // offered that rep's routes rather than their own region's.
  Future<void> _loadRoutes() async {
    try {
      final r = await Api.getRoutes(forRep: _rep);
      if (!mounted) return;
      setState(() {
        _routes = r;
        // The previous rep's route may not exist in this one's region.
        if (_route != _allRoutes && !r.contains(_route)) _route = _allRoutes;
      });
    } catch (_) {
      // A missing route list shouldn't block the day's points.
    }
  }

  Future<void> _loadRoute() async {
    if (_route == _allRoutes) {
      setState(() => _routePoints = []);
      return;
    }
    final route = _route;
    setState(() {
      _loadingRoute = true;
      _error = null;
    });
    try {
      final list = await Api.getCustomersInTerritory(route);
      final pts = <_MapPoint>[];
      for (final c in list) {
        final lat = _num(c['custom_latitude']);
        final lng = _num(c['custom_longitude']);
        if (!isMappableLatLng(lat, lng)) continue;
        pts.add(_MapPoint(
            lat: lat,
            lng: lng,
            kind: 'customer',
            title: '${c['customer_name'] ?? c['name']}',
            subtitle: [route, c['customer_group']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' · '),
            color: const Color(0xFFDB2777),
            icon: Icons.location_pin));
      }
      if (mounted) setState(() => _routePoints = pts);
    } catch (e) {
      if (mounted) setState(() => _error = humanError(e));
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _loadLeads() async {
    if (!_showLeads) {
      setState(() => _leadPoints = []);
      return;
    }
    setState(() {
      _loadingLeads = true;
      _error = null;
    });
    try {
      final list = await Api.getLeadsWithLocation(
          territory: _route == _allRoutes ? null : _route);
      final pts = <_MapPoint>[];
      for (final l in list) {
        final lat = _num(l['custom_latitude']);
        final lng = _num(l['custom_longitude']);
        if (!isMappableLatLng(lat, lng)) continue;
        pts.add(_MapPoint(
            lat: lat,
            lng: lng,
            kind: 'lead',
            title: '${l['lead_name'] ?? l['name']}',
            subtitle: [
              'Lead',
              l['status'],
              l['territory'],
              l['custom_location_status'],
            ].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
            color: const Color(0xFF4338CA),
            icon: Icons.person_pin));
      }
      if (mounted) setState(() => _leadPoints = pts);
    } catch (e) {
      if (mounted) setState(() => _error = humanError(e));
    } finally {
      if (mounted) setState(() => _loadingLeads = false);
    }
  }

  // Fetched once, then the chips just switch the markers on and off.
  Future<void> _loadLayers({bool force = false}) async {
    if (!_showVisits && !_showLeadVisits) return;
    if (_layersLoaded && !force) return;
    setState(() {
      _loadingLayers = true;
      _error = null;
    });
    try {
      final res = await Api.getMyVisitsWithLocation(days: _visitDays);
      final vis = <_MapPoint>[];
      final leadVis = <_MapPoint>[];
      for (final v in res) {
        final lat = _num(v['check_in_latitude']);
        final lng = _num(v['check_in_longitude']);
        if (!isMappableLatLng(lat, lng)) continue;
        final isLead = Api.isLeadVisit(v);
        (isLead ? leadVis : vis).add(_MapPoint(
            lat: lat,
            lng: lng,
            kind: 'my_visit',
            title: Api.visitParty(v),
            subtitle: [
              isLead ? 'Lead visit' : 'Visit',
              '${v['visit_date']}',
              _fmtTime(v['check_in_time']),
              '${v['visit_status']}',
            ].where((x) => x.isNotEmpty && x != 'null').join(' · '),
            color: isLead ? const Color(0xFF0F766E) : const Color(0xFFF46A21),
            icon: isLead ? Icons.person_pin_circle : Icons.store));
      }
      if (mounted) {
        setState(() {
          _myVisitPoints = vis;
          _myLeadVisitPoints = leadVis;
          _layersLoaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = humanError(e));
    } finally {
      if (mounted) setState(() => _loadingLayers = false);
    }
  }

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _dateLabel(DateTime d) {
    final t = DateTime.now();
    if (d.year == t.year && d.month == t.month && d.day == t.day) {
      return 'Today';
    }
    return '${d.day}/${d.month}/${d.year}';
  }

  String _fmtTime(dynamic dt) {
    if (dt == null) return '';
    final d = DateTime.tryParse('$dt'.replaceFirst(' ', 'T'));
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _load() async {
    final rep = _rep;
    if (rep == null || rep.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final ds = _dateStr(_date);
    try {
      final res = await Future.wait([
        Api.getAttendanceForDay(rep, ds),
        Api.getVisitsForDay(rep, ds),
        Api.getTripsForDay(rep, ds),
      ]);
      final pts = <_MapPoint>[];
      for (final a in res[0]) {
        final inLat = _num(a['punch_in_latitude']);
        final inLng = _num(a['punch_in_longitude']);
        if (isMappableLatLng(inLat, inLng)) {
          pts.add(_MapPoint(
              lat: inLat,
              lng: inLng,
              kind: 'punch_in',
              title: 'Punch in',
              subtitle: 'Attendance · ${_fmtTime(a['punch_in_time'])}',
              color: const Color(0xFF16A34A),
              icon: Icons.login));
        }
        final outLat = _num(a['punch_out_latitude']);
        final outLng = _num(a['punch_out_longitude']);
        if (isMappableLatLng(outLat, outLng)) {
          pts.add(_MapPoint(
              lat: outLat,
              lng: outLng,
              kind: 'punch_out',
              title: 'Punch out',
              subtitle: 'Attendance · ${_fmtTime(a['punch_out_time'])}',
              color: Colors.red,
              icon: Icons.logout));
        }
      }
      for (final v in res[1]) {
        final lat = _num(v['check_in_latitude']);
        final lng = _num(v['check_in_longitude']);
        if (isMappableLatLng(lat, lng)) {
          final isLead = Api.isLeadVisit(v);
          pts.add(_MapPoint(
              lat: lat,
              lng: lng,
              kind: isLead ? 'lead_visit' : 'visit',
              title: Api.visitParty(v),
              subtitle:
              '${isLead ? 'Lead visit' : 'Check-in'} · ${_fmtTime(v['check_in_time'])}',
              color: isLead
                  ? const Color(0xFF0F766E)
                  : const Color(0xFFF46A21),
              icon: isLead ? Icons.person_pin_circle : Icons.store));
        }
      }
      for (final t in res[2]) {
        final sLat = _num(t['start_latitude']);
        final sLng = _num(t['start_longitude']);
        if (isMappableLatLng(sLat, sLng)) {
          pts.add(_MapPoint(
              lat: sLat,
              lng: sLng,
              kind: 'trip_start',
              title: 'Trip start',
              subtitle:
              '${t['purpose'] ?? t['name']} · ${_fmtTime(t['start_time'])}',
              color: const Color(0xFF2563EB),
              icon: Icons.play_circle_fill));
        }
        final eLat = _num(t['end_latitude']);
        final eLng = _num(t['end_longitude']);
        if (isMappableLatLng(eLat, eLng)) {
          pts.add(_MapPoint(
              lat: eLat,
              lng: eLng,
              kind: 'trip_end',
              title: 'Trip end',
              subtitle:
              '${t['purpose'] ?? t['name']} · ${_fmtTime(t['end_time'])}',
              color: const Color(0xFF7C3AED),
              icon: Icons.flag));
        }
      }
      if (mounted) setState(() => _points = pts);
    } catch (e) {
      if (mounted) setState(() => _error = humanError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (d != null) {
      setState(() => _date = d);
      _load();
    }
  }

  void _showPoint(_MapPoint p) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(p.icon, color: p.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(p.title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 6),
            Text(p.subtitle),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                navigateTo(p.lat, p.lng);
              },
              icon: const Icon(Icons.directions),
              label: const Text('Navigate here'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(children: [
        Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(_dateLabel(_date)),
          ),
        ),
        if (_canPick) ...[
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _rep,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              ),
              items: _reps
                  .map((r) => DropdownMenuItem(
                value: r['name'] as String,
                child: Text('${r['label']}',
                    overflow: TextOverflow.ellipsis),
              ))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _rep = v);
                _load();
                // Routes are region-scoped, so the list changes with the rep.
                final before = _route;
                _loadRoutes().then((_) {
                  // The pick fell outside the new rep's region — drop the
                  // overlays that were drawn for it.
                  if (mounted && _route != before) {
                    _loadRoute();
                    _loadLeads();
                  }
                });
              },
            ),
          ),
        ],
        ]),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _route,
          isExpanded: true,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.alt_route, size: 18),
            border: const OutlineInputBorder(),
            contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            suffixIcon: _loadingRoute
                ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
                : null,
          ),
          items: [
            const DropdownMenuItem(
                value: _allRoutes, child: Text('All routes')),
            ..._routes.map((r) => DropdownMenuItem(
                value: r, child: Text(r, overflow: TextOverflow.ellipsis))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _route = v);
            _loadRoute();
            // Leads follow the picked route, so reload them alongside it.
            _loadLeads();
          },
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            FilterChip(
              selected: _showLeads,
              avatar: _loadingLeads
                  ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_pin, size: 18),
              label: Text(_route == _allRoutes
                  ? 'Show leads'
                  : 'Show leads on $_route'),
              onSelected: (v) {
                setState(() => _showLeads = v);
                _loadLeads();
              },
            ),
            FilterChip(
              selected: _showVisits,
              avatar: _loadingLayers
                  ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.store, size: 18),
              label: Text(_layersLoaded
                  ? 'Visits (${_myVisitPoints.length})'
                  : 'Visits'),
              onSelected: (v) {
                setState(() => _showVisits = v);
                _loadLayers();
              },
            ),
            FilterChip(
              selected: _showLeadVisits,
              avatar: _loadingLayers
                  ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_pin_circle, size: 18),
              label: Text(_layersLoaded
                  ? 'Lead visits (${_myLeadVisitPoints.length})'
                  : 'Lead visits'),
              onSelected: (v) {
                setState(() => _showLeadVisits = v);
                _loadLayers();
              },
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _legend() {
    Widget chip(Color c, IconData ic, String t) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, color: c, size: 16),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11)),
        ]);
    return Container(
      padding: const EdgeInsets.all(12),
      child: Wrap(spacing: 14, runSpacing: 8, children: [
        chip(const Color(0xFF16A34A), Icons.login, 'Punch in'),
        chip(Colors.red, Icons.logout, 'Punch out'),
        chip(const Color(0xFFF46A21), Icons.store, 'Visit'),
        chip(const Color(0xFF0F766E), Icons.person_pin_circle, 'Lead visit'),
        chip(const Color(0xFF2563EB), Icons.play_circle_fill, 'Trip start'),
        chip(const Color(0xFF7C3AED), Icons.flag, 'Trip end'),
        if (_route != _allRoutes)
          chip(const Color(0xFFDB2777), Icons.location_pin,
              '$_route customer (${_routePoints.length})'),
        if (_showLeads)
          chip(const Color(0xFF4338CA), Icons.person_pin,
              'Lead (${_leadPoints.length})'),
        if (_showVisits || _showLeadVisits)
          Text('my visits: last $_visitDays days',
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
      ]),
    );
  }

  Widget _map() {
    final all = [
      ..._routePoints,
      ..._leadPoints,
      if (_showVisits) ..._myVisitPoints,
      if (_showLeadVisits) ..._myLeadVisitPoints,
      ..._points,
    ];
    if (all.isEmpty) {
      final overlays = <String>[
        if (_route != _allRoutes) 'no customer on this route has coordinates',
        if (_showLeads) 'no lead has a captured location',
        if (_showVisits) 'no visit in the last $_visitDays days has a location',
        if (_showLeadVisits)
          'no lead visit in the last $_visitDays days has a location',
      ];
      return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
                overlays.isEmpty
                    ? 'No GPS points for this day.'
                    : 'No GPS points for this day, and ${overlays.join(', and ')} yet.',
                textAlign: TextAlign.center),
          ));
    }
    final latlngs = all.map((p) => LatLng(p.lat, p.lng)).toList();
    final markers = all
        .map((p) => Marker(
      point: LatLng(p.lat, p.lng),
      width: 44,
      height: 44,
      child: GestureDetector(
        onTap: () => _showPoint(p),
        child: Icon(p.icon, color: p.color, size: 40),
      ),
    ))
        .toList();
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
      appBar: AppBar(title: const Text('Day Map'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _load();
              _loadRoute();
              _loadLeads();
              _loadLayers(force: true);
            }),
      ]),
      body: Column(children: [
        _controls(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _map(),
        ),
        _legend(),
      ]),
    );
  }
}

// -------------------- LEAVE --------------------
// Financial year (Apr 1 - Mar 31) that contains `d`.
({String start, String end, int label}) financialYear(DateTime d) {
  final y = d.month >= 4 ? d.year : d.year - 1;
  return (start: '$y-04-01', end: '${y + 1}-03-31', label: y);
}

