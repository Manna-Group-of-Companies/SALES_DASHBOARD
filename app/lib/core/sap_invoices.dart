// What a rep has to collect: Manna Treads' A/R invoices, as SAP holds them.
//
// The user, 27 Nov 2026: once Manna invoices, the Collections page shows the
// amount to collect. The figures are SAP's own: B1iF's invoices package
// mirrors every open invoice (and this year's closed ones) into the
// `SAP Invoice` doctype, and its payments package mirrors incoming payments
// into `SAP Payment` (sap-b1if/erpnext/manna_sap_invoices.py, _payments.py).
// `balance` is SAP's total less SAP's paid, worked out by the sync; this file
// only adds rows up and dates them - it never recomputes a balance.

double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}') ?? 0;
}

String _text(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

/// An invoice still owing money: SAP says Open and something is left on it.
/// A balance under a rupee is SAP's rounding, not money to chase.
bool invoiceOpen(Map<String, dynamic> inv) =>
    _text(inv['status']) == 'Open' && _num(inv['balance']) >= 1;

/// The amount to collect across [invoices]: the open balances, summed.
double toCollect(Iterable<Map<String, dynamic>> invoices) {
  final sum = invoices
      .where(invoiceOpen)
      .fold<double>(0, (t, inv) => t + _num(inv['balance']));
  return double.parse(sum.toStringAsFixed(2));
}

/// Past its due date with money still on it, on [today] (`YYYY-MM-DD`).
/// An invoice with no due date is not called overdue: there is no date to be
/// past, and a red figure nobody can explain is worse than none.
bool invoiceOverdue(Map<String, dynamic> inv, String today) {
  final due = _text(inv['due_date']);
  if (!invoiceOpen(inv) || due.length < 10) return false;
  return due.substring(0, 10).compareTo(today.substring(0, 10)) < 0;
}

/// Open invoices, the longest overdue first - the order a rep should chase.
List<Map<String, dynamic>> openInvoicesByDue(
        Iterable<Map<String, dynamic>> invoices) =>
    invoices.where(invoiceOpen).toList()
      ..sort((a, b) =>
          _text(a['due_date']).compareTo(_text(b['due_date'])));

/// `2026-11-23` -> `23-11-2026`; anything else as it came.
String dmy(dynamic iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(_text(iso));
  return m == null ? _text(iso) : '${m[3]}-${m[2]}-${m[1]}';
}
