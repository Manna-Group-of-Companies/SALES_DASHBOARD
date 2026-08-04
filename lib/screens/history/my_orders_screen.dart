
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/history_list.dart';

class MyOrdersScreen extends StatelessWidget {
  const MyOrdersScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return HistoryList(
      title: 'My Orders',
      loader: Api.getMyOrders,
      cacheKey: CacheKeys.orders,
      tileBuilder: (ctx, r) {
        final po = '${r['custom_po_status'] ?? '—'}';
        final approved = po == 'PO Approved - Ready for SAP';
        final prod = '${r['custom_production_status'] ?? ''}';
        final fin = '${r['custom_production_finish_date'] ?? ''}';
        final dd = '${r['delivery_date'] ?? ''}';
        final ddText =
        (dd.isNotEmpty && dd != 'null') ? '  ·  Required by: $dd' : '';
        final statusLine = approved
            ? 'Production: ${prod.isEmpty ? 'Not Started' : prod}'
            '${(fin.isNotEmpty && fin != 'null') ? '  ·  est. finish $fin' : ''}'
            : approvalLabel(po);
        return ListTile(
          leading: const Icon(Icons.shopping_cart),
          title: Text(r['customer'] ?? r['name']),
          subtitle: Text(
              '${r['transaction_date'] ?? ''}$ddText\nProforma: ${r['custom_proforma_status'] ?? '—'}  ·  $statusLine'),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(ctx).push(MaterialPageRoute(
              builder: (_) => OrderDetailScreen(orderName: r['name'] as String))),
        );
      },
    );
  }
}

