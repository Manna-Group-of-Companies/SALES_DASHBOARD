import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/leads/add_lead_screen.dart';
import 'package:manna_field_sales/screens/leads/lead_order_detail_screen.dart';
import 'package:manna_field_sales/screens/leads/lead_order_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/widgets/route_picker.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';
import 'package:manna_field_sales/widgets/visit_punch_card.dart';

class LeadDetailScreen extends StatefulWidget {
  final Map<String, dynamic> lead;
  const LeadDetailScreen({super.key, required this.lead});
  @override
  State<LeadDetailScreen> createState() => _LeadDetailScreenState();
}

class _LeadDetailScreenState extends State<LeadDetailScreen> {
  late Future<List<Map<String, dynamic>>> _ordersFut;
  late Map<String, dynamic> _l;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _l = Map<String, dynamic>.from(widget.lead);
    _ordersFut = Api.getLeadOrders(lead: widget.lead['name'] as String);
  }

  void _reload() => setState(() {
        _ordersFut = Api.getLeadOrders(lead: widget.lead['name'] as String);
      });

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  String get _locStatus =>
      (_l['custom_location_status'] ?? 'Not Captured').toString();
  bool get _submitted => _locStatus == 'Pending Verification';
  bool get _verified => _locStatus == 'Verified';

  /// A visit can only start once the location is on record. Awaiting the
  /// manager's verification is enough — the rep isn't blocked by that queue.
  /// 'Rejected' does not count: that location has to be captured again.
  bool get _locationCaptured => _submitted || _verified;

  /// One-time location capture for the lead. This never logs a visit —
  /// punching in on the visit card is the only thing that creates a visit.
  Future<void> _capture() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    final img = await pickPhoto(context, title: 'Location / banner photo');
    if (img == null) return _snack('A location/banner photo is required.');
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      await Api.captureLeadLocation(
        lead: _l['name'] as String,
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      await Api.uploadPhoto(
        doctype: 'Lead',
        docname: _l['name'] as String,
        fieldname: 'custom_banner_photo',
        filePath: img.path,
        filename: 'lead_banner.jpg',
      );
      setState(() {
        _l['custom_location_status'] = 'Pending Verification';
        _l['custom_latitude'] = pos.latitude;
        _l['custom_longitude'] = pos.longitude;
      });
      _snack('Captured - sent for manager verification.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final updated = await Navigator.push<Map<String, dynamic>>(context,
        MaterialPageRoute(builder: (_) => AddLeadScreen(lead: _l)));
    if (updated != null && mounted) setState(() => _l.addAll(updated));
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      appBar: AppBar(title: Text(l['lead_name'] ?? l['name']), actions: [
        IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit lead',
            onPressed: _busy ? null : _edit),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l['lead_name'] ?? l['name'],
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text([l['company_name'], l['mobile_no']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' · ')),
            const SizedBox(height: 4),
            // Shown even when unset. A lead that converts with no route leaves
            // production unable to plan its first delivery.
            RouteChip(route: '${l['custom_sales_route'] ?? ''}'),
            if ('${l['email_id'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('✉ ${l['email_id']}',
                    style: const TextStyle(fontSize: 13, color: Colors.black87)),
              ),
            if ('${l['custom_address'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${l['custom_address']}',
                    style: const TextStyle(fontSize: 13, color: Colors.black87)),
              ),
            if ('${l['custom_gstin'] ?? ''}'.isNotEmpty ||
                '${l['custom_payment_terms'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text([
                  if ('${l['custom_gstin'] ?? ''}'.isNotEmpty)
                    'GST ${l['custom_gstin']}',
                  if ('${l['custom_payment_terms'] ?? ''}'.isNotEmpty)
                    'Terms: ${l['custom_payment_terms']}',
                ].join('  ·  '),
                    style: const TextStyle(fontSize: 13, color: Colors.black54)),
              ),
            const SizedBox(height: 16),
            Card(
              color: const Color(0xFFFFF3E0),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.location_on,
                            color: Color(0xFFF46A21)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text('Location: $_locStatus',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600))),
                      ]),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: (_busy || _submitted || _verified)
                              ? null
                              : _capture,
                          icon: Icon(_verified
                              ? Icons.verified
                              : _submitted
                                  ? Icons.hourglass_top
                                  : Icons.my_location),
                          label: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text(_verified
                                ? 'Verified'
                                : _submitted
                                    ? 'Submitted for verification'
                                    : (_locStatus == 'Rejected'
                                        ? 'Re-capture Location'
                                        : 'Capture Location')),
                          ),
                        ),
                      ),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            VisitPunchCard(
                lead: l['name'] as String,
                locationCaptured: _locationCaptured),
            const SizedBox(height: 12),
            SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => LeadOrderScreen(lead: l)))
                      .then((_) => _reload()),
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Take Order from Lead')),
                )),
            const SizedBox(height: 12),
            const Text('Lead Orders',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ]),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _ordersFut,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const Center(
                    child: Text('No orders for this lead yet.'));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = rows[i];
                  return ListTile(
                    leading: const Icon(Icons.receipt_long),
                    title: Text('${r['name']}  ·  Rs ${(r['total_amount'] ?? 0)}'),
                    subtitle:
                    Text('${r['order_date'] ?? ''}  ·  ${r['status'] ?? ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        ctx,
                        MaterialPageRoute(
                            builder: (_) => LeadOrderDetailScreen(
                                orderName: r['name'] as String,
                                lead: widget.lead)))
                        .then((_) => _reload()),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

