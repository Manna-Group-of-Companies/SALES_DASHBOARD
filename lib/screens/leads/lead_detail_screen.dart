import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/leads/add_lead_screen.dart';
import 'package:manna_field_sales/screens/leads/lead_order_detail_screen.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';
import 'package:manna_field_sales/widgets/sites_section.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/widgets/route_picker.dart';
import 'package:manna_field_sales/widgets/route_required_gate.dart';
import 'package:manna_field_sales/widgets/proximity_gate.dart';
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
  /// manager's verification is enough -- the rep is not blocked by that queue.
  /// 'Rejected' does not count: that location has to be captured again.
  bool get _locationCaptured => _submitted || _verified;

  /// One-time location capture for the lead. This never logs a visit —
  /// punching in on the visit card is the only thing that creates a visit.
  ///
  /// A rep photographs the place and their capture waits for the manager to
  /// confirm the coordinates belong to it. A manager's own capture skips both
  /// -- they are the person who would be checking it.
  Future<void> _capture() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');
    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation();
      if (!mounted) return;
      // The lead being captured sits at zero metres from itself, so it is
      // excluded — otherwise the first capture would always block.
      final clear = await ensureNothingNearby(
        context,
        lat: pos.latitude,
        lng: pos.longitude,
        subject: 'put this lead on the map',
        exclude: {_l['name'] as String},
      );
      if (!clear || !mounted) return;

      // Asked for after the duplicate check, not before. Photographing a
      // shopfront and only then being told the shop is already on record
      // wastes the one part of this that costs the rep time.
      XFile? img;
      if (Api.locationPhotoRequired) {
        img = await pickPhoto(context, title: 'Location / banner photo');
        if (img == null) return _snack('A location/banner photo is required.');
      }

      await Api.captureLeadLocation(
        lead: _l['name'] as String,
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (img != null) {
        await Api.uploadPhoto(
          doctype: 'Lead',
          docname: _l['name'] as String,
          fieldname: 'custom_banner_photo',
          filePath: img.path,
          filename: 'lead_banner.jpg',
        );
      }
      final selfVerified = !Api.locationPhotoRequired;
      setState(() {
        _l['custom_location_status'] =
            selfVerified ? 'Verified' : 'Pending Verification';
        _l['custom_latitude'] = pos.latitude;
        _l['custom_longitude'] = pos.longitude;
        if (selfVerified) {
          _l['custom_verified_latitude'] = pos.latitude;
          _l['custom_verified_longitude'] = pos.longitude;
        }
      });
      _snack(selfVerified
          ? 'Location captured ✓'
          : 'Captured — sent for manager verification.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final updated = await Navigator.push<Map<String, dynamic>>(context,
        MaterialPageRoute(builder: (_) => AddLeadScreen(lead: _l)));
    if (updated != null && mounted) setState(() => _l.addAll(updated));
  }

  /// What this lead still owes before an order against it can be approved.
  ///
  /// Tapping it opens the edit form, because the point is to fix it now rather
  /// than to be told about it.
  Widget _missingCard(List<String> missing) => Card(
        color: const Color(0xFFFFF1F0),
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : _edit,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.report_problem_outlined,
                    size: 18, color: Color(0xFFB3261E)),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Details missing',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                Icon(Icons.edit, size: 16, color: Color(0xFFB3261E)),
              ]),
              const SizedBox(height: 6),
              Text(
                'You can take an order, but your manager cannot approve it '
                'until this lead has: ${missing.join(', ')}.',
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 4),
              const Text('Tap to fill them in.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
          ),
        ),
      );

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
            // What the manager will refuse to approve on, said here instead of
            // at the far end of the process. A rep standing in the shop can ask
            // for the GST number; a rep back in the van two days later cannot.
            if (missingLeadDetails(l).isNotEmpty) ...[
              const SizedBox(height: 12),
              _missingCard(missingLeadDetails(l)),
            ],
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
                                ? 'Location captured'
                                : _submitted
                                    ? 'Captured'
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
                  // The same order screen a customer gets. A lead sells the
                  // same products in the same units against the same minimum
                  // stock, so it takes the same order — the difference shows up
                  // once, at approval.
                  onPressed: () async {
                    // A lead may be missing everything else and still be
                    // ordered from — the manager catches the rest at approval.
                    // The route is the exception: it cannot be added after the
                    // order exists and has already reached the floor.
                    final party = OrderParty.lead(l);
                    if (!await ensureRouteSet(context, party)) return;
                    if (!context.mounted) return;
                    await Navigator.push(context,
                        MaterialPageRoute(
                            builder: (_) => OrderScreen(party: party)));
                    _reload();
                  },
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Take Order from Lead')),
                )),
            const SizedBox(height: 12),
            // A lead can have several premises before it is ever converted —
            // a shop and a godown are two drops on two runs. Captured here so
            // the routes are already right on the day it becomes a customer,
            // rather than being redone from scratch afterwards.
            SitesSection(lead: l['name'] as String),
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
                return Center(child: Text(humanError(snap.error)));
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

