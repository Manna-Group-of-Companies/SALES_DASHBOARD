// `Manna Production Order` — the two flows in shared/PRODUCTION_FLOWS.md.
//
// Only what the stock manager's receiving screen needs: replenishment orders
// (purpose Stock) not yet received onto the shelf. Flow B (order-attached
// production) is tracked on the Sales Order line itself and never reaches
// this screen except through the cancel-after-production exception.

import 'package:manna_field_sales/models/product_category.dart';

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

int _int(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

String _clean(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return (s.isEmpty || s == 'null') ? '' : s;
}

class ProductionOrder {
  final String name;
  final String itemCode;
  final double qty;
  final int looseBelts;

  /// `Open` / `In Production` / `Made` / `Received` / `Dispatched` / `Cancelled`.
  final String status;
  final String raisedOn;
  final String raisedBy;

  ProductionOrder({
    required this.name,
    required this.itemCode,
    required this.qty,
    required this.status,
    required this.raisedOn,
    required this.raisedBy,
    this.looseBelts = 0,
  });

  factory ProductionOrder.fromJson(Map<String, dynamic> j) => ProductionOrder(
        name: '${j['name']}',
        itemCode: _clean(j['item_code']),
        qty: _num(j['qty']),
        looseBelts: _int(j['loose_belts']),
        status: _clean(j['status']),
        raisedOn: _clean(j['raised_on']),
        raisedBy: _clean(j['raised_by']),
      );
}

/// A production order together with the item it names — the receiving
/// screen needs a name and a unit, not just a code.
class ProductionOrderDetail {
  final ProductionOrder order;
  final Product product;

  ProductionOrderDetail({required this.order, required this.product});

  String get name => product.name;
  String get unit => product.category.stockUnit;
}
