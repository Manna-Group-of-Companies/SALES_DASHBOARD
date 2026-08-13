
import 'package:flutter/material.dart';


class RetreadOrderDetailScreen extends StatelessWidget {
  final String orderRef;
  final List<Map<String, dynamic>> tyres;
  const RetreadOrderDetailScreen(
      {super.key, required this.orderRef, required this.tyres});

  Color _stColor(String s) {
    switch (s) {
      case 'Invoiced':
        return const Color(0xFF2563EB);
      case 'Delivered':
        return Colors.green;
      case 'Scheduled':
        return Colors.teal;
      default:
        return const Color(0xFF7C3AED);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cust = tyres.isNotEmpty
        ? '${tyres.first['customer_name'] ?? tyres.first['customer'] ?? ''}'
        : '';
    final date = tyres.isNotEmpty ? '${tyres.first['order_date'] ?? ''}' : '';
    final total = tyres.fold<double>(
        0,
            (s, t) => s + ((t['rate'] is num) ? (t['rate'] as num).toDouble() : 0));
    return Scaffold(
      appBar: AppBar(title: Text(orderRef.isEmpty ? 'Order' : orderRef)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(cust,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
            'Ordered $date  ·  ${tyres.length} tyre(s)  ·  ₹${total.toStringAsFixed(0)}'),
        const SizedBox(height: 16),
        const Text('Tyres', style: TextStyle(fontWeight: FontWeight.bold)),
        const Divider(),
        ...tyres.map((t) {
          final st = '${t['status'] ?? ''}';
          final rate =
          (t['rate'] is num) ? (t['rate'] as num).toDouble() : 0.0;
          final extra = <String>[];
          final dd = '${t['delivery_date'] ?? ''}';
          if (dd.isNotEmpty && dd != 'null') extra.add('deliver $dd');
          final veh = '${t['vehicle'] ?? ''}';
          if (veh.isNotEmpty) extra.add(veh);
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading:
            const Icon(Icons.circle, size: 10, color: Color(0xFFF46A21)),
            title: Text('${t['tyre_number'] ?? t['name']}'),
            subtitle: Text('${t['tyre_size'] ?? ''} · ${t['retread_type'] ?? ''}'
                '${extra.isNotEmpty ? '  ·  ${extra.join(' · ')}' : ''}'),
            trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('₹${rate.toStringAsFixed(0)}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(st,
                      style: TextStyle(fontSize: 11, color: _stColor(st))),
                ]),
          );
        }),
      ]),
    );
  }
}
