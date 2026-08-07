
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/screens/leads/lead_order_detail_screen.dart';
import 'package:manna_field_sales/screens/orders/combined_order_screen.dart';
import 'package:manna_field_sales/screens/orders/order_detail_screen.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/history_list.dart';
import 'package:manna_field_sales/widgets/order_complete_tick.dart';

class MyOrdersScreen extends StatelessWidget {
  const MyOrdersScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return HistoryList(
      title: 'My Orders',
      loader: Api.getMyOrders,
      cacheKey: CacheKeys.orders,
      tileBuilder: (ctx, r, _) {
        // A closed week arrives as one row standing for all of its orders.
        // Its members are not listed separately — see Api.getMyOrders — so the
        // same money is never counted twice down the screen.
        if (r['is_combined'] == true) {
          final count = (r['order_count'] ?? 0);
          return ListTile(
            leading: const Icon(Icons.merge_type, color: Color(0xFF6D4C41)),
            title: Text('${r['customer'] ?? r['name']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '${r['name']}  ·  week ${r['week_start'] ?? ''} to ${r['week_end'] ?? ''}'
                '\n$count ${count == 1 ? 'order' : 'orders'} combined  ·  '
                'Rs ${r['grand_total'] ?? 0}'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => CombinedOrderScreen(combined: r))),
          );
        }

        final isLead = r['is_lead'] == true;
        // Set once the production manager has closed the week this order fell
        // in. The rep sees it so that a customer asking about "last week's
        // order" and the office looking at one combined document are talking
        // about the same thing.
        final combinedRaw = '${r['custom_combined_order'] ?? ''}'.trim();
        final combined =
            (combinedRaw.isEmpty || combinedRaw == 'null') ? '' : combinedRaw;
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
          title: Row(children: [
            Expanded(child: Text(r['customer'] ?? r['name'])),
            // A lead order is not a Sales Order yet, so it has no production
            // status to tick — showing an empty box against one would read as
            // "not finished" rather than "not applicable".
            if (!isLead) OrderCompleteTick(order: r, compact: true),
          ]),
          subtitle: Text('${r['transaction_date'] ?? ''}$ddText\n$statusLine'
              '${combined.isEmpty ? '' : '\nWeek order: $combined'}'),
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

