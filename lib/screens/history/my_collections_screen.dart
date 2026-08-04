
import 'package:flutter/material.dart';

import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/share_service.dart';
import 'package:manna_field_sales/widgets/history_list.dart';

class MyCollectionsScreen extends StatelessWidget {
  const MyCollectionsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return HistoryList(
      title: 'My Collections',
      loader: Api.getMyCollections,
      cacheKey: CacheKeys.collections,
      tileBuilder: (ctx, r) => ListTile(
        leading: const Icon(Icons.payments),
        title: Text(r['customer'] ?? r['name']),
        subtitle: Text(
            '${r['collection_date'] ?? ''}  ·  ${r['mode_of_payment'] ?? ''}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('₹${(r['amount'] ?? 0)}'),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share on WhatsApp',
            onPressed: () => shareOnWhatsApp(ctx,
                'Payment received from ${r['customer']}: ₹${r['amount']} via ${r['mode_of_payment']} (${r['collection_date']})'),
          ),
        ]),
      ),
    );
  }
}

// -------------------- MAP --------------------
// Paste a free MapTiler key here to get English (Latin) map labels everywhere,
// including UAE. Get one at https://www.maptiler.com (free tier). Leave empty
// to use standard OpenStreetMap tiles (which show local-language labels).
