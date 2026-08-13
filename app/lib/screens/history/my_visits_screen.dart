
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/history_list.dart';

class MyVisitsScreen extends StatelessWidget {
  const MyVisitsScreen({super.key});

  /// Removes a visit logged by mistake — the wrong shop tapped, or a check-in
  /// that never became a call.
  ///
  /// Only offered on the rep's own visits. A visit logged by somebody else and
  /// shared through a trip belongs to them, and one rep quietly deleting
  /// another's day is not something this app should make easy.
  static Future<void> _delete(
      BuildContext context, Map<String, dynamic> r, VoidCallback reload) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this visit?'),
        content: Text('${Api.visitParty(r)} on ${r['visit_date'] ?? ''}.\n\n'
            'It will stop counting towards your visits and will come off the '
            'day map. This cannot be undone.'),
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

    final messenger = ScaffoldMessenger.of(context);
    try {
      await Api.deleteVisit('${r['name']}');
      messenger.showSnackBar(const SnackBar(content: Text('Visit deleted ✓')));
      reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(humanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = Session.I.salesPerson;
    return HistoryList(
      title: 'My Visits',
      loader: Api.getMyVisitsIncludingTagged,
      cacheKey: CacheKeys.visits,
      tileBuilder: (ctx, r, reload) {
        final by = '${r['sales_person'] ?? ''}';
        final shared = by.isNotEmpty && by != me;
        final isLead = Api.isLeadVisit(r);
        return ListTile(
          leading: Icon(
              shared
                  ? Icons.group
                  : (isLead ? Icons.person_pin_circle : Icons.location_on),
              color: shared ? const Color(0xFFF46A21) : null),
          title: Text(Api.visitParty(r)),
          subtitle: Text('${isLead ? 'Lead  ·  ' : ''}'
              '${r['visit_date'] ?? ''}  ·  ${r['visit_status'] ?? ''}'
              '${shared ? '  ·  logged by $by' : '  ·  ${r['name'] ?? ''}'}'),
          trailing: shared
              ? const Chip(
                  label: Text('Shared', style: TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Color(0xFFFFE8DC))
              : IconButton(
                  tooltip: 'Delete visit',
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 20),
                  onPressed: () => _delete(ctx, r, reload),
                ),
        );
      },
    );
  }
}
