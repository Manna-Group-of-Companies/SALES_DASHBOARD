// The extra premises a party has, beyond the one location used for check-in.
//
// A customer or a lead can have a second shop, a godown, a yard across town.
// Each is a separate drop with its own route: a customer's warehouse may sit on
// an entirely different run from their office, so the route is set per site and
// never inherited from the party.
//
// Shared between the customer and lead screens on purpose. The two have already
// drifted apart once in this codebase — territory versus sales route lingered on
// leads months after customers moved — and a second copy of this flow would
// drift the same way.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/location_service.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';
import 'package:manna_field_sales/widgets/route_picker.dart';

class SitesSection extends StatefulWidget {
  /// The customer these sites belong to. Exactly one of [customer] and [lead]
  /// is set — a site hangs off one party, never both.
  final String? customer;
  final String? lead;

  const SitesSection({super.key, this.customer, this.lead})
      : assert(customer != null || lead != null,
            'A site needs a customer or a lead to belong to');

  @override
  State<SitesSection> createState() => _SitesSectionState();
}

class _SitesSectionState extends State<SitesSection> {
  List<Map<String, dynamic>> _sites = [];
  bool _loading = true;
  bool _busy = false;

  bool get _isLead => widget.lead != null;
  String get _party => widget.lead ?? widget.customer!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = _isLead
          ? await Api.getLeadSites(_party)
          : await Api.getCustomerSites(_party);
      if (mounted) {
        setState(() {
          _sites = s;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _add() async {
    final rep = Session.I.salesPerson;
    if (rep == null) return _snack('No rep linked to this login.');

    final ctrl = TextEditingController();
    final siteName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New site name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Godown, Branch 2'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Next')),
        ],
      ),
    );
    if (siteName == null || siteName.isEmpty) return;
    if (!mounted) return;

    final img = await pickPhoto(context, title: 'Site banner photo');
    if (img == null) return _snack('A site banner photo is required.');

    setState(() => _busy = true);
    _snack('Getting GPS…');
    try {
      final pos = await getCurrentLocation();
      final created = await Api.createCustomerSite(
        customer: widget.customer,
        lead: widget.lead,
        siteName: siteName,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      await Api.uploadPhoto(
        doctype: 'Customer Site',
        docname: created,
        fieldname: 'banner_photo',
        filePath: img.path,
        filename: 'site_banner.jpg',
      );
      _snack('Site "$siteName" captured — sent for manager verification.');
      await _load();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Puts one site on a route. Never touches the party's own route.
  Future<void> _setRoute(Map<String, dynamic> site) async {
    final current = '${site['route'] ?? ''}';
    final picked = await pickSalesRoute(context,
        current: current.isEmpty || current == 'null' ? null : current,
        title: 'Route for ${site['site_name']}');
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      await Api.setSiteRoute('${site['name']}', picked);
      setState(() => site['route'] = picked);
      _snack('Site route set.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> site) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this site?'),
        content: Text('${site['site_name']} will be removed.\n\n'
            'Its captured location and route go with it. This cannot be '
            'undone.'),
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
      await Api.deleteSite('${site['name']}');
      _snack('Site deleted ✓');
      await _load();
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Sites',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        TextButton.icon(
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add_location_alt, size: 18),
            label: const Text('Add site')),
      ]),
      if (_loading)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('Loading sites…',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        )
      else if (_sites.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
              _isLead
                  ? 'No extra sites. The main location is used for check-in; '
                      'add a site for a second shop or godown. Sites follow the '
                      'lead through to becoming a customer.'
                  : 'No extra sites. The main location is used for check-in; '
                      'add a site for a second shop or godown.',
              style: const TextStyle(fontSize: 12, color: Colors.black45)),
        )
      else
        ..._sites.map(_siteCard),
    ]);
  }

  Widget _siteCard(Map<String, dynamic> s) {
    final st = '${s['location_status']}';
    final (Color col, IconData ic) = switch (st) {
      'Verified' => (Colors.green, Icons.verified),
      'Pending Verification' => (Colors.orange, Icons.hourglass_top),
      'Rejected' => (Colors.red, Icons.cancel),
      _ => (Colors.grey, Icons.location_off),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(ic, color: col),
        title: Text('${s['site_name']}'),
        subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(st),
              RouteChip(
                route: '${s['route'] ?? ''}',
                onTap: _busy ? null : () => _setRoute(s),
              ),
            ]),
        trailing: IconButton(
          tooltip: 'Delete site',
          icon: const Icon(Icons.delete_outline,
              color: Colors.redAccent, size: 20),
          onPressed: _busy ? null : () => _delete(s),
        ),
      ),
    );
  }
}
