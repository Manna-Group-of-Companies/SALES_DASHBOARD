// Item requests (10 Nov 2026): a rep asks for a product that is not in the
// catalogue; the accountant creates it in SAP and answers with its code, or
// rejects it. Read and written only through the manna_item_request Server
// Script (app/server/item_request.py), which decides who may do what.
//
// The rep's manager approves first (12 Nov 2026): 'Pending Manager', then
// 'Pending' with the accountant. shared/fixtures/item_request_flow.json pins
// the stage names and when the accountant may answer; the dashboard's copy is
// client/src/api/itemRequests.ts.

const String kItemRequestWithManager = 'Pending Manager';
const String kItemRequestWithAccountant = 'Pending';

/// What a request's stage is called, to the rep and to the manager.
/// Anything not known reads as still with the manager: it offers nobody an
/// answer, which is the safe way for an unknown status to fall.
String itemRequestLabel(String status) => switch (status) {
      kItemRequestWithAccountant => 'With accountant',
      'Done' => 'Done',
      'Rejected' => 'Rejected',
      _ => 'With manager',
    };

/// Whether the accountant may answer it: only once the manager has approved.
bool accountantAnswers(String status) => status == kItemRequestWithAccountant;

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
  final String salesPerson;
  final String managerNote;
  /// The server's word that this user may approve it now (item_request.py).
  final bool canApprove;

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
    this.salesPerson = '',
    this.managerNote = '',
    this.canApprove = false,
  });

  factory ItemRequest.fromJson(Map m) => ItemRequest(
        name: _s(m['name']),
        status: _s(m['status']).isEmpty ? kItemRequestWithManager : _s(m['status']),
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
        salesPerson: _s(m['sales_person']),
        managerNote: _s(m['manager_note']),
        canApprove: _s(m['can_approve']) == '1' || m['can_approve'] == true,
      );

  String get label => itemRequestLabel(status);

  /// "Black Pearl · VIKING · 215 x 135": what was asked for, in one line.
  String get title => [productLine, pattern, size].where((s) => s.isNotEmpty).join(' · ');
}
