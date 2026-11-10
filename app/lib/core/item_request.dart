// Item requests (10 Nov 2026): a rep asks for a product that is not in the
// catalogue; the accountant creates it in SAP and answers with its code, or
// rejects it. Read and written only through the manna_item_request Server
// Script (app/server/item_request.py), which decides who may do what.

const List<String> kItemRequestLines = [
  'Black Pearl', 'Platinum', 'Silver', 'Polygold', 'Diamond', 'Hot', 'Bonding Gum', 'Solution', 'Other',
];
const List<String> kItemRequestTypes = ['Precured', 'Hot', 'Bonding Gum', 'Solution', 'Other'];
const List<String> kItemRequestUnits = ['Rolls', 'Kg', 'Nos', 'Litre'];

String _s(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

class ItemRequest {
  final String name;
  final String status;
  final String productLine;
  final String itemType;
  final String pattern;
  final String size;
  final String customerName;
  final double quantity;
  final String unit;
  final String note;
  final String requestedOn;
  final String itemCode;
  final String reply;

  const ItemRequest({
    required this.name,
    required this.status,
    required this.productLine,
    required this.itemType,
    required this.pattern,
    required this.size,
    required this.customerName,
    required this.quantity,
    required this.unit,
    required this.note,
    required this.requestedOn,
    required this.itemCode,
    required this.reply,
  });

  factory ItemRequest.fromJson(Map m) => ItemRequest(
        name: _s(m['name']),
        status: _s(m['status']).isEmpty ? 'Pending' : _s(m['status']),
        productLine: _s(m['product_line']),
        itemType: _s(m['item_type']),
        pattern: _s(m['pattern']),
        size: _s(m['size']),
        customerName: _s(m['customer_name']).isNotEmpty ? _s(m['customer_name']) : _s(m['customer']),
        quantity: m['quantity'] is num ? (m['quantity'] as num).toDouble() : double.tryParse(_s(m['quantity'])) ?? 0,
        unit: _s(m['unit']),
        note: _s(m['note']),
        requestedOn: _s(m['requested_on']),
        itemCode: _s(m['item_code']),
        reply: _s(m['reply']),
      );

  /// "Black Pearl · VIKING · 215 x 135": what was asked for, in one line.
  String get title => [productLine, pattern, size].where((s) => s.isNotEmpty).join(' · ');
}
