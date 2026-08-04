import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/leads/add_lead_screen.dart';
import 'package:manna_field_sales/screens/leads/lead_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/offline_banner.dart';

class LeadsScreen extends StatefulWidget {
  const LeadsScreen({super.key});
  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends State<LeadsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  String _q = '';
  @override
  void initState() {
    super.initState();
    _future = Api.getLeads();
  }

  void _reload() => setState(() { _future = Api.getLeads(); });

  bool _match(Map<String, dynamic> r) {
    if (_q.isEmpty) return true;
    final hay = [
      r['lead_name'],
      r['company_name'],
      r['mobile_no'],
      r['territory'],
      r['status']
    ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_q.toLowerCase());
  }

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
              final rows = all.where(_match).toList();
              return Column(children: [
                OfflineBanner.forKey(CacheKeys.leads),
                Expanded(
                  child: all.isEmpty
                      ? const Center(
                          child: Text('No leads yet. Tap “Add Lead”.'))
                      : rows.isEmpty
                          ? const Center(child: Text('No matches.'))
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
            subtitle: Text([r['company_name'], r['territory'], r['mobile_no']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(ctx,
                    MaterialPageRoute(builder: (_) => LeadDetailScreen(lead: r)))
                .then((_) => _reload()),
          );
        },
      );
}

