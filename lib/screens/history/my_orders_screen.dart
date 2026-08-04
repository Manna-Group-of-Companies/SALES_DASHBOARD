
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/screens/leads/lead_order_detail_screen.dart';
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
        final isLead = r['is_lead'] == true;
        final dd = '${r['delivery_date'] ?? ''}';
        final ddText =
            (dd.isNotEmpty && dd != 'null') ? '  ·  Required by: $dd' : '';

        // A lead order has no proforma and no production status — it is not a
        // Sales Order until the manager approves and the lead converts — so it
        // carries its own single status line rather than empty columns.
        final String statusLine;
        if (isLead) {
          statusLine = 'Lead order  ·  ${r['status'] ?? ''}';
        } else {
          final po = '${r['custom_po_status'] ?? '—'}';
          final approved = po == 'PO Approved - Ready for SAP';
          final prod = '${r['custom_production_status'] ?? ''}';
          final fin = '${r['custom_production_finish_date'] ?? ''}';
          statusLine = 'Proforma: ${r['custom_proforma_status'] ?? '—'}  ·  '
              '${approved ? 'Production: ${prod.isEmpty ? 'Not Started' : prod}'
                  '${(fin.isNotEmpty && fin != 'null') ? '  ·  est. finish $fin' : ''}' : approvalLabel(po)}';
        }

        return ListTile(
          leading: Icon(isLead ? Icons.emoji_objects : Icons.shopping_cart,
              color: isLead ? const Color(0xFF5C6BC0) : null),
          title: Text(r['customer'] ?? r['name']),
          subtitle: Text('${r['transaction_date'] ?? ''}$ddText\n$statusLine'),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (isLead) {
              Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => LeadOrderDetailScreen(
                        orderName: r['name'] as String,
                        lead: {
                          'name': r['lead'],
                          'lead_name': r['lead_name'],
                        },
                      )));
              return;
            }
            Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) =>
                    OrderDetailScreen(orderName: r['name'] as String)));
          },
        );
      },
    );
  }
}

