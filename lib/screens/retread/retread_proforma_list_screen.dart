import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/screens/retread/new_retread_proforma_screen.dart';
import 'package:manna_field_sales/screens/retread/retread_proforma_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';

class RetreadProformaListScreen extends StatefulWidget {
  const RetreadProformaListScreen({super.key});
  @override
  State<RetreadProformaListScreen> createState() =>
      _RetreadProformaListScreenState();
}

class _RetreadProformaListScreenState extends State<RetreadProformaListScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = Api.getMyRetreadProformas();
  }

  void _reload() => setState(() => _future = Api.getMyRetreadProformas());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Retread Rate Proformas'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const NewRetreadProformaScreen()));
          _reload();
        },
        icon: const Icon(Icons.add),
        label: const Text('New proforma'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text(humanError(snap.error)));
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'No rate proformas yet. Tap "New proforma" to set retread rates for a customer.',
                        textAlign: TextAlign.center)));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = items[i];
              final superseded = '${p['status']}' == 'Superseded';
              return ListTile(
                leading: Icon(Icons.request_quote,
                    color: superseded ? Colors.grey : const Color(0xFFF46A21)),
                title: Text('${p['customer_name'] ?? p['customer'] ?? ''}'),
                subtitle: Text('${p['name']}  ·  ${p['proforma_date'] ?? ''}'),
                trailing: Text('${p['status'] ?? ''}',
                    style: TextStyle(
                        fontSize: 12,
                        color: superseded ? Colors.grey : Colors.green)),
                onTap: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => RetreadProformaDetailScreen(
                              name: p['name'] as String)));
                  _reload();
                },
              );
            },
          );
        },
      ),
    );
  }
}

