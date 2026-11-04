// Monthly sales targets, and how far each rep is towards theirs.
//
// What counts as achieved is decided once, on the server, by the
// `manna_sales_targets` Server Script (app/server/sales_targets.py): only
// order lines SAP has invoiced, dated in the target's month. Until 3 Nov 2026
// the phone added up approved orders itself, which counted an order the day it
// was approved whether or not it was ever invoiced.
//
// The phone only turns the script's totals into a fraction. That step is
// pinned by shared/fixtures/sales_target_progress.json; the TypeScript twin is
// client/src/domain/salesTarget.ts.

const List<String> kTargetMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// One order line SAP has invoiced.
class InvoicedLine {
  final String order;
  final String customerName;
  final String itemName;
  final String invoice;
  final String invoiceDate;
  final double amount;
  final double kg;

  const InvoicedLine({
    required this.order,
    required this.customerName,
    required this.itemName,
    required this.invoice,
    required this.invoiceDate,
    required this.amount,
    required this.kg,
  });

  factory InvoicedLine.fromJson(Map m) => InvoicedLine(
        order: '${m['order'] ?? ''}',
        customerName: '${m['customer_name'] ?? ''}',
        itemName: '${m['item_name'] ?? ''}',
        invoice: '${m['invoice'] ?? ''}',
        invoiceDate: '${m['invoice_date'] ?? ''}',
        amount: _num(m['amount']),
        kg: _num(m['kg']),
      );
}

/// A rep's target for the month and what SAP has invoiced against it.
class TargetRow {
  final String salesPerson;
  final String currency;
  final String? targetName;
  final double targetAmount;

  /// `Currency` or `Tonnes`; anything else reads as `Currency`.
  final String unit;
  final double invoicedAmount;
  final double invoicedKg;

  /// What the rep's customers owe, from the SAP credit sync. Not month-bound.
  final double outstanding;

  /// The part of [outstanding] overdue past the customers' payment terms.
  final double overdue;
  final List<InvoicedLine> lines;

  /// How many lines were invoiced: `lines.length`, unless `line_count` says
  /// otherwise (the fixture states a count without listing lines).
  final int lineCount;

  const TargetRow({
    required this.salesPerson,
    this.currency = 'INR',
    this.targetName,
    required this.targetAmount,
    required this.unit,
    required this.invoicedAmount,
    required this.invoicedKg,
    this.outstanding = 0,
    this.overdue = 0,
    this.lines = const [],
    int? lineCount,
  }) : lineCount = lineCount ?? lines.length;

  factory TargetRow.fromJson(Map m) {
    final lines = ((m['lines'] as List?) ?? const [])
        .whereType<Map>()
        .map(InvoicedLine.fromJson)
        .toList();
    final unit = '${m['target_unit'] ?? ''}';
    return TargetRow(
      salesPerson: '${m['sales_person'] ?? ''}',
      currency: '${m['currency'] ?? 'INR'}',
      targetName: m['target_name'] as String?,
      targetAmount: _num(m['target_amount']),
      unit: unit == 'Tonnes' ? 'Tonnes' : 'Currency',
      invoicedAmount: _num(m['invoiced_amount']),
      invoicedKg: _num(m['invoiced_kg']),
      outstanding: _num(m['outstanding']),
      overdue: _num(m['overdue']),
      lines: lines,
      lineCount: (m['line_count'] as num?)?.toInt(),
    );
  }

  bool get isTonnes => unit == 'Tonnes';
  bool get hasTarget => targetAmount > 0;
  bool get hasInvoices => lineCount > 0;

  /// Achieved in the target's own unit: tonnes, or money.
  double get achieved => isTonnes ? invoicedKg / 1000 : invoicedAmount;

  /// Achieved over target, not capped — past target reads past 1.0. Zero when
  /// there is no target. Clamp it for a progress bar, never for the number.
  double get fraction => hasTarget ? achieved / targetAmount : 0;

  /// Money in the rep's currency, whatever the target's unit.
  String money(double v) => '$currency ${v.toStringAsFixed(0)}';

  /// "AED 1,20,000" or "12.5 t".
  String format(double v) => isTonnes
      ? '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)} t'
      : '$currency ${v.toStringAsFixed(0)}';
}

/// What `manna_sales_targets` returns for one month.
class TargetMonth {
  final String month;
  final int year;
  final bool isGM;

  /// Reps whose target this login may set: a manager's own team, nobody else.
  final Set<String> canEdit;
  final List<TargetRow> rows;

  const TargetMonth({
    required this.month,
    required this.year,
    required this.isGM,
    required this.canEdit,
    required this.rows,
  });

  factory TargetMonth.fromJson(Map m) => TargetMonth(
        month: '${m['month'] ?? ''}',
        year: (m['year'] as num?)?.toInt() ?? 0,
        isGM: m['is_gm'] == 1 || m['is_gm'] == true,
        canEdit: ((m['can_edit'] as List?) ?? const [])
            .map((e) => '$e')
            .toSet(),
        rows: ((m['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map(TargetRow.fromJson)
            .toList(),
      );

  TargetRow? rowFor(String? salesPerson) {
    if (salesPerson == null) return null;
    for (final r in rows) {
      if (r.salesPerson == salesPerson) return r;
    }
    return null;
  }
}
