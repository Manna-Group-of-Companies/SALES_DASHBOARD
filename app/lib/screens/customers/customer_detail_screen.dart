import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:url_launcher/url_launcher.dart';

import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/widgets/credit_conditions_section.dart';
import 'package:manna_field_sales/widgets/sap_sync_bar.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/screens/collections/collection_screen.dart';
import 'package:manna_field_sales/screens/customers/customer_edit_screen.dart';
import 'package:manna_field_sales/screens/complaints/complaint_screen.dart';
import 'package:manna_field_sales/screens/orders/order_screen.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';
import 'package:manna_field_sales/widgets/route_required_gate.dart';
import 'package:manna_field_sales/widgets/sites_section.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/services/map_service.dart';
import 'package:manna_field_sales/widgets/visit_punch_card.dart';

class CustomerDetailScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  final List<Map<String, dynamic>> reps;
  const CustomerDetailScreen(
      {super.key, required this.customer, required this.reps});
  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late Map<String, dynamic> c;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    c = Map<String, dynamic>.from(widget.customer);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  /// Lets a rep fix the details while they are standing in the shop — above
  /// all the route, which production needs before an order is worth taking.
  /// The customer is re-read afterwards rather than patched locally, so the
  /// screen shows what the server actually stored.
  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CustomerEditScreen(customer: c)));
    if (saved != true) return;
    setState(() => _busy = true);
    try {
      final fresh = await Api.getCustomerDoc(c['name'] as String);
      if (mounted) setState(() => c = {...c, ...fresh});
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _status =>
      (c['custom_location_status'] ?? 'Not Captured').toString();

  /// A visit can only start once the shop location is on record. Awaiting the
  /// manager's verification is enough -- the rep is not blocked by that queue.
  /// 'Rejected' does not count: that location has to be captured again.
  bool get _locationCaptured =>
      _status == 'Pending Verification' || _status == 'Verified';

  /// Captures the shop location once. This never logs a visit — punching in
  /// on the visit card is the only thing that creates a Sales Visit.
  ///
  /// A rep photographs the shopfront and their capture waits for the manager
  /// to confirm the coordinates belong to it. A manager's own capture skips
  /// both — they are the person who would be checking it, and the photo exists
  /// only for that check.
  ///
  /// [recapture] is the rep saying the pin already on record is in the wrong
  /// place. It is confirmed first: it overwrites a location the office may
  /// have relied on for months, and a rep who taps it from the road rather
  /// than from the counter would move the shop to the road.
  Future<void> _capture({bool recapture = false}) async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');

    if (recapture && !await _confirmRecapture()) return;
    if (!mounted) return;

    XFile? img;
    if (Api.locationPhotoRequired) {
      img = await pickPhoto(context, title: 'Shop banner photo');
      if (img == null) return _snack('A shop banner photo is required.');
    }

    setState(() => _busy = true);
    _snack('Getting GPS...');
    try {
      final pos = await getCurrentLocation(requireAccurate: true);
      await Api.captureCustomerLocation(
        customer: c['name'],
        salesPerson: rep,
        lat: pos.latitude,
        lng: pos.longitude,
        recapture: recapture,
        existingLat: _num(c['custom_verified_latitude']),
        existingLng: _num(c['custom_verified_longitude']),
      );
      if (img != null) {
        await Api.uploadPhoto(
          doctype: 'Customer',
          docname: c['name'],
          fieldname: 'custom_banner_photo',
          filePath: img.path,
          filename: 'banner.jpg',
        );
      }
      final selfVerified = !Api.locationPhotoRequired;
      setState(() {
        c['custom_location_status'] =
            selfVerified ? 'Verified' : 'Pending Verification';
        c['custom_latitude'] = pos.latitude;
        c['custom_longitude'] = pos.longitude;
        if (selfVerified) {
          c['custom_verified_latitude'] = pos.latitude;
          c['custom_verified_longitude'] = pos.longitude;
        } else if (recapture) {
          // Mirrors what the write just cleared on the server, so the punch
          // card measures against the new pin without a reload.
          c['custom_verified_latitude'] = null;
          c['custom_verified_longitude'] = null;
        }
      });
      _snack(selfVerified
          ? 'Location captured ✓'
          : recapture
              ? 'Location corrected — you can punch in now.'
              : 'Captured — sent for manager verification.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirms a re-capture, naming the one thing that makes it wrong.
  ///
  /// The rep must be at the shop. Everything else about this is recoverable —
  /// the manager still verifies it — but a pin taken from the road replaces a
  /// good location with a worse one, and nothing downstream can tell.
  Future<bool> _confirmRecapture() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Correct this shop\'s location?'),
          content: const Text(
            'This replaces the saved location with where you are standing '
            'right now, and sends it to your manager to verify.\n\n'
            'Only do this if you are at the shop.',
            style: TextStyle(fontSize: 13.5, height: 1.4),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('I am at the shop')),
          ],
        ),
      ) ??
      false;

  static double _num(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack('No dialler available.');
    }
  }

  /// The customer's own particulars — route, group, phone, ERP id and, once
  /// the shop has been captured, its coordinates with a way to navigate there.
  Widget _detailsSection() {
    final lat = _num(c['custom_latitude']);
    final lng = _num(c['custom_longitude']);
    final mappable = isMappableLatLng(lat, lng);
    final phone = '${c['custom_phone'] ?? ''}'.trim();

    Widget row(IconData ic, String label, String value, {Widget? action}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(ic, size: 18, color: Colors.black45),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45)),
                    Text(value, style: const TextStyle(fontSize: 14)),
                  ]),
            ),
            ?action,
          ]),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(children: [
          // Reads the Sales Route, not the Territory. This row was left on
          // `territory` when routes moved to their own doctype, so it stayed
          // blank however carefully the route was assigned.
          row(
              Icons.alt_route,
              'Route',
              ('${c['custom_sales_route'] ?? ''}'.isEmpty ||
                      '${c['custom_sales_route']}' == 'null')
                  ? 'Not set'
                  : '${c['custom_sales_route']}'),
          row(
              Icons.category_outlined,
              'Group',
              '${c['customer_group'] ?? ''}'.isEmpty
                  ? '—'
                  : '${c['customer_group']}'),
          row(Icons.phone, 'Phone', phone.isEmpty ? '—' : phone,
              action: phone.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Call',
                      icon: const Icon(Icons.call, color: Colors.green),
                      onPressed: () => _call(phone))),
          row(Icons.badge_outlined, 'Customer ID', '${c['name']}'),
          row(
              Icons.location_on_outlined,
              'Location',
              mappable
                  ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                  : 'Not captured',
              action: mappable
                  ? IconButton(
                      tooltip: 'Navigate',
                      icon: const Icon(Icons.directions, color: Colors.blue),
                      onPressed: () => navigateTo(lat, lng))
                  : null),
        ]),
      ),
    );
  }

  Widget _creditSection() {
    // Read through core/credit.dart, which is the only place that knows the
    // stored total beats the sum of the buckets and that four zeros mean
    // "not synced" rather than "nothing due". Paired with the dashboard's
    // client/src/domain/credit.ts and pinned by shared/fixtures/credit.json.
    final a = agingOf(c);
    final over = a.creditLimit > 0 && a.total > a.creditLimit;

    Widget box(String label, String value, Color? bg) => Expanded(
      child: Card(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
    );

    // One age bucket. Narrower than the two headline boxes because four of
    // them share a row, and only the oldest is coloured — if every box
    // shouted, none would.
    Widget bucket(AgingBucket b) => Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        color: b.overdue ? const Color(0xFFFFEBEE) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.label,
                style: const TextStyle(fontSize: 10, color: Colors.black54)),
            const SizedBox(height: 3),
            // A dash, not a zero, when SAP has sent no breakdown — see
            // kAgingNoData. Zero would say "nothing due in this band", which
            // is a statement nobody has the data to make.
            Text(a.bucketsKnown ? '₹${b.amount.toStringAsFixed(0)}' : kAgingNoData,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: (b.overdue && a.bucketsKnown)
                        ? Colors.red.shade700
                        : null)),
          ]),
        ),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        box('Outstanding', '₹${a.total.toStringAsFixed(0)}',
            a.total > 0 ? const Color(0xFFFFF3E0) : null),
        // A single figure, because SAP sends a single figure. Only the
        // outstanding is aged.
        box('Credit Limit',
            a.creditLimit > 0 ? '₹${a.creditLimit.toStringAsFixed(0)}' : '—',
            over ? const Color(0xFFFFEBEE) : null),
      ]),

      // Directly under the two figures it describes. A limit raised this
      // morning does not reach here until the nightly job runs, and a rep
      // being refused by a stale number has no other way to tell.
      const SapSyncBar(),

      // How old the debt is. Shown, never enforced: the credit rule is still
      // the total against the limit, and nothing here blocks an order.
      // The buckets are always drawn, synced or not: a reader can then see
      // WHICH bands are unknown, and the four labels stay in the same place
      // either way. The explanation follows underneath when there is one.
      const SizedBox(height: 4),
      Row(children: a.buckets.map(bucket).toList()),
      if (!a.bucketsKnown)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(kAgingNotSynced,
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
        ),

      if (a.mismatch)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(kAgingMismatch,
              style: TextStyle(fontSize: 11, color: Colors.orange.shade900)),
        ),

      if (over)
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: const Color(0xFFFFEBEE),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: const [
            Icon(Icons.warning_amber, color: Colors.red, size: 20),
            SizedBox(width: 8),
            Expanded(
                child: Text(
                    'Over credit limit — proforma will need manager release.',
                    style: TextStyle(color: Colors.red))),
          ]),
        ),
    ]);
  }

  /// Shop location capture, independent of visits. Once submitted the main
  /// button only reports where the location sits in the manager's queue —
  /// but a wrong pin can still be corrected underneath it.
  ///
  /// That correction is not a convenience. A pin captured from the wrong place
  /// puts the shop outside the punch-in radius for good, and until this button
  /// existed there was no way back: the rep's capture was disabled, and the
  /// manager's queue only ever lists captures already awaiting verification.
  Widget _locationSection() {
    final s = _status;
    final submitted = s == 'Pending Verification';
    final verified = s == 'Verified';

    final Color col = verified
        ? Colors.green
        : submitted
            ? Colors.orange
            : Colors.grey;
    final IconData ic = verified
        ? Icons.verified
        : submitted
            ? Icons.hourglass_top
            : Icons.my_location;
    final String label = verified
        ? 'Location captured'
        : submitted
            ? 'Captured'
            : 'Capture Location';

    return Column(children: [
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor:
                verified || submitted ? col.withValues(alpha: 0.12) : null,
            foregroundColor: verified || submitted ? col : null,
            disabledBackgroundColor: col.withValues(alpha: 0.12),
            disabledForegroundColor: col,
          ),
          onPressed: (_busy || verified || submitted) ? null : _capture,
          icon: Icon(ic),
          label: Padding(padding: const EdgeInsets.all(12), child: Text(label)),
        ),
      ),
      if (verified || submitted)
        TextButton.icon(
          onPressed: _busy ? null : () => _capture(recapture: true),
          icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
          label: const Text('Location wrong? Re-capture'),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(c['customer_name'] ?? c['name']),
        actions: [
          IconButton(
            tooltip: 'Edit customer',
            icon: const Icon(Icons.edit),
            onPressed: _busy ? null : _edit,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child:
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(c['customer_name'] ?? c['name'],
              style:
              const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          // Group only. The route lives in the details card below — showing it
          // twice invited exactly the confusion it caused, where the card read
          // blank while the line under the name read fine.
          Text(('${c['customer_group'] ?? ''}' == 'null')
              ? ''
              : '${c['customer_group'] ?? ''}'),
          // The route is what production plans deliveries by, so its absence
          // is worth saying out loud rather than showing an empty line.
          if ('${c['custom_sales_route'] ?? ''}'.isEmpty ||
              '${c['custom_sales_route']}' == 'null')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(Icons.route, size: 14, color: Colors.orange.shade800),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('No sales route set — production cannot plan a '
                      'delivery for this customer.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade800)),
                ),
              ]),
            ),
          const SizedBox(height: 16),
          _detailsSection(),
          const SizedBox(height: 16),
          _creditSection(),
          // Directly under the credit figures, because that is what a
          // condition is about — the GM let an over-limit order through and
          // this is what was promised in return. Renders nothing at all when
          // the customer has none, which is most of them.
          const SizedBox(height: 16),
          CreditConditionsSection(customer: c['name'] as String),
          const SizedBox(height: 16),
          _locationSection(),
          const SizedBox(height: 16),
          VisitPunchCard(
              customer: c['name'] as String,
              locationCaptured: _locationCaptured,
              onLocationWrong: () => _capture(recapture: true)),
          const SizedBox(height: 16),
          SitesSection(customer: c['name'] as String),
          const SizedBox(height: 16),
          if (Session.I.company != 'Manna Tyre Retreads') ...[
            FilledButton.tonalIcon(
              // Checked before the order screen opens, not when it is saved.
              // Refusing a full basket at the counter wastes the rep's time
              // and the customer's.
              onPressed: () async {
                final party = OrderParty.customer(c);
                if (!await ensureRouteSet(context, party)) return;
                if (!context.mounted) return;
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => OrderScreen(party: party)));
              },
              icon: const Icon(Icons.shopping_cart),
              label: const Padding(
                  padding: EdgeInsets.all(12), child: Text('New Order')),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    CollectionScreen(customer: c, reps: widget.reps))),
            icon: const Icon(Icons.payments),
            label: const Padding(
                padding: EdgeInsets.all(12), child: Text('Record Collection')),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.deepOrange),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ComplaintScreen(customer: c))),
            icon: const Icon(Icons.report_problem_outlined),
            label: const Padding(
                padding: EdgeInsets.all(12), child: Text('Raise Complaint')),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
        ]),
      ),
    );
  }
}

// -------------------- PROFORMA / PO PDF --------------------
