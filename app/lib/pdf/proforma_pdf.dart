import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/proforma_columns.dart';

String _amountInWords(num amount) {
  final n = amount.round();
  if (n == 0) return 'Zero';
  const ones = [
    '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
    'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
    'Seventeen', 'Eighteen', 'Nineteen'
  ];
  const tens = [
    '', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty',
    'Ninety'
  ];
  String two(int x) => x < 20
      ? ones[x]
      : tens[x ~/ 10] + (x % 10 != 0 ? ' ${ones[x % 10]}' : '');
  String three(int x) {
    final h = x ~/ 100, r = x % 100;
    return (h > 0 ? '${ones[h]} Hundred${r > 0 ? ' ' : ''}' : '') +
        (r > 0 ? two(r) : '');
  }

  int crore = n ~/ 10000000, rest = n % 10000000;
  int lakh = rest ~/ 100000;
  rest %= 100000;
  int thousand = rest ~/ 1000;
  rest %= 1000;
  final parts = <String>[];
  if (crore > 0) parts.add('${three(crore)} Crore');
  if (lakh > 0) parts.add('${two(lakh)} Lakh');
  if (thousand > 0) parts.add('${two(thousand)} Thousand');
  if (rest > 0) parts.add(three(rest));
  return parts.join(' ').trim();
}

// ---- PDF-safe coercion (built-in font is Latin-1 only; non-Latin glyphs throw) ----
String _pdfSafe(dynamic v) {
  final t = (v ?? '').toString().replaceAll('\u20b9', 'Rs ');
  return t.replaceAll(RegExp(r'[^\x20-\x7E\n]'), '');
}

num _pdfNum(dynamic v) =>
    v is num ? v : (num.tryParse('${v ?? ''}') ?? 0);

// Public entry: try the full invoice; if anything throws during layout,
// fall back to a guaranteed-render simple invoice so we never emit a blank page.
Future<Uint8List> buildProformaPdf({
  required Map<String, dynamic> order,
  required Map<String, dynamic> customer,
  required bool isPurchaseOrder,
}) async {
  try {
    return await _richProforma(order, customer, isPurchaseOrder);
  } catch (e) {
    return await _simpleProforma(order, customer, isPurchaseOrder, '$e');
  }
}

Future<Uint8List> _richProforma(Map<String, dynamic> order,
    Map<String, dynamic> customer, bool isPurchaseOrder) async {
  final doc = pw.Document();
  final items = (order['items'] as List?) ?? [];
  final title = isPurchaseOrder ? 'PURCHASE ORDER' : 'PROFORMA INVOICE';
  final df = DateTime.tryParse(order['transaction_date']?.toString() ?? '') ??
      DateTime.now();
  final dateStr =
      '${df.day.toString().padLeft(2, '0')}/${df.month.toString().padLeft(2, '0')}/${df.year}';
  double total = 0;
  for (final it in items) {
    total += _pdfNum(it['amount']).toDouble();
  }
  final custName = _pdfSafe(customer['customer_name'] ?? order['customer'] ?? '');
  final custPhone = _pdfSafe(customer['custom_phone'] ?? '');
  final custTerr = _pdfSafe(customer['territory'] ?? '');
  // Billing address and GSTIN come off the Customer record, which is loaded
  // from the same Excel import as the products. `gstin` is checked as well as
  // the custom field so a site already running India Compliance keeps working.
  // `custom_address` is the field the customer master has actually been filled
  // in with; `custom_billing_address` exists as a print-specific override for
  // the cases where the two should differ.
  final custAddr = _pdfSafe(customer['custom_billing_address'] ??
      customer['custom_address'] ??
      customer['primary_address'] ??
      '');
  final custGst =
      _pdfSafe(customer['custom_gstin'] ?? customer['gstin'] ?? '');
  final custState = _pdfSafe(customer['custom_state'] ?? '');

  pw.TextStyle st(double sz, {bool b = false}) => pw.TextStyle(
      fontSize: sz,
      fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal);

  pw.Widget cell(String t,
      {pw.TextAlign a = pw.TextAlign.left, bool b = false}) =>
      pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: pw.Text(t, textAlign: a, style: st(7.5, b: b)));

  pw.Widget kvTable(List<List<String>> rows,
      {bool rightValue = false, double labelW = 70}) =>
      pw.Table(
        columnWidths: {
          0: pw.FixedColumnWidth(labelW),
          1: const pw.FlexColumnWidth(),
        },
        children: [
          for (final kv in rows)
            pw.TableRow(children: [
              pw.Padding(
                  padding: const pw.EdgeInsets.all(2),
                  child: pw.Text(kv[0], style: st(7))),
              pw.Padding(
                  padding: const pw.EdgeInsets.all(2),
                  child: pw.Text(rightValue ? kv[1] : ': ${kv[1]}',
                      style: st(7),
                      textAlign:
                      rightValue ? pw.TextAlign.right : pw.TextAlign.left)),
            ]),
        ],
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(18),
    build: (context) => [
      // ----- title -----
      pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
                child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(kCoName, style: st(15, b: true)),
                      pw.Text(kCoAddress, style: st(7.5)),
                      pw.Text('GST No : $kCoGST', style: st(7.5)),
                    ])),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text(title, style: st(13, b: true)),
              pw.Text('ORIGINAL', style: st(7)),
            ]),
          ]),
      pw.SizedBox(height: 6),
      // ----- bill-to + meta -----
      pw.Container(
        decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
        padding: const pw.EdgeInsets.all(5),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            flex: 5,
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Bill To :', style: st(8, b: true)),
                  pw.Text(custName, style: st(9)),
                  if (custAddr.isNotEmpty) pw.Text(custAddr, style: st(7.5)),
                  if (custTerr.isNotEmpty) pw.Text(custTerr, style: st(7.5)),
                  if (custPhone.isNotEmpty)
                    pw.Text('Phone: $custPhone', style: st(7.5)),
                  if (custGst.isNotEmpty)
                    pw.Text('GSTIN : $custGst', style: st(7.5, b: true)),
                  if (custState.isNotEmpty)
                    pw.Text('State : $custState', style: st(7.5)),
                  pw.SizedBox(height: 4),
                  pw.Text('Ship To :', style: st(8, b: true)),
                  pw.Text(custName, style: st(7.5)),
                  if (custAddr.isNotEmpty) pw.Text(custAddr, style: st(7.5)),
                ]),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(
              flex: 5,
              child: kvTable([
                ['Invoice No.', '${order['name'] ?? ''}'],
                ['Invoice Date', dateStr],
                ['Due Date', ''],
                ['Reference', ''],
                ['Buyers Order No', ''],
                ['Dispatch Through', ''],
                ['Vehicle No.', ''],
                ['Destination', ''],
              ])),
        ]),
      ),
      pw.SizedBox(height: 6),
      // ----- items -----
      pw.Table(
          border: pw.TableBorder.all(width: 0.5),
          columnWidths: {
            0: const pw.FixedColumnWidth(18),   // #
            1: const pw.FlexColumnWidth(3),     // Description
            2: const pw.FixedColumnWidth(30),   // Rolls
            3: const pw.FixedColumnWidth(30),   // Belts
            4: const pw.FixedColumnWidth(30),   // Cans
            5: const pw.FixedColumnWidth(48),   // Qty
            6: const pw.FixedColumnWidth(48),   // MRP
            7: const pw.FixedColumnWidth(52),   // Amount
          },
          children: [
            pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  cell('Sr', b: true),
                  cell('Description', b: true),
                  cell('Rolls', b: true, a: pw.TextAlign.right),
                  cell('Belts', b: true, a: pw.TextAlign.right),
                  cell('Cans', b: true, a: pw.TextAlign.right),
                  cell('Qty', b: true, a: pw.TextAlign.right),
                  cell('MRP', b: true, a: pw.TextAlign.right),
                  cell('Amount', b: true, a: pw.TextAlign.right),
                ]),
            for (var k = 0; k < items.length; k++)
              () {
                // Every figure comes out of core/proforma_columns.dart, which
                // the dashboard's renderer also uses. A column that differed
                // between the two would be a customer sent two versions of the
                // same quote.
                final c = proformaCells(items[k].cast<String, dynamic>());
                return pw.TableRow(children: [
                  cell('${k + 1}'),
                  // The item name alone. Rolls, belts and cans used to be
                  // appended here as a sentence; they are quantities, and they
                  // now have columns of their own.
                  cell(_pdfSafe(items[k]['item_name'] ?? items[k]['item_code'])),
                  cell(c.rolls, a: pw.TextAlign.right),
                  cell(c.belts, a: pw.TextAlign.right),
                  cell(c.cans, a: pw.TextAlign.right),
                  cell(c.qty, a: pw.TextAlign.right),
                  // The unit sits under the figure so the row can be checked:
                  // tread rubber and gum multiply out on Qty, solution on Cans.
                  cell(
                      c.mrpUnit.isEmpty
                          ? c.mrp.toStringAsFixed(2)
                          : '${c.mrp.toStringAsFixed(2)}\n${c.mrpUnit}',
                      a: pw.TextAlign.right),
                  cell(c.amount.toStringAsFixed(2), a: pw.TextAlign.right),
                ]);
              }(),
            // The total belongs to the table it totals. A customer reading
            // down the Amount column should find the sum at the bottom of it,
            // not in a separate box further down the page.
            pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  cell(''),
                  cell('Total', b: true),
                  cell(''),
                  cell(''),
                  cell(''),
                  cell(''),
                  cell(''),
                  cell(total.toStringAsFixed(2), b: true, a: pw.TextAlign.right),
                ]),
          ]),
      pw.SizedBox(height: 6),
      // ----- words + totals -----
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
            flex: 5,
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Amount Chargeable (in words)', style: st(8, b: true)),
                  pw.Text('INR ${_amountInWords(total)} Only', style: st(7.5)),
                ])),
        pw.SizedBox(width: 10),
        // No tax box. The rate a rep quotes already includes GST, so a
        // breakup here would either restate the same money or invite somebody
        // to add it twice. Tax is settled on the invoice, not on a quote.
      ]),
      pw.SizedBox(height: 8),
      // ----- bank + signatory -----
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text("Company's Bank Details", style: st(8, b: true)),
                  pw.Text('Bank Name : $kBankName', style: st(7.5)),
                  pw.Text('Branch : $kBankBranch', style: st(7.5)),
                  pw.Text('A/C Number : $kBankAcc', style: st(7.5)),
                  pw.Text('IFSC : $kBankIFSC', style: st(7.5)),
                  pw.Text("Company's PAN : $kCoPAN", style: st(7.5)),
                ])),
        pw.Expanded(
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('For $kCoName', style: st(7.5)),
                  pw.SizedBox(height: 22),
                  pw.Text('Authorised Signatory', style: st(7.5)),
                ])),
      ]),
      pw.SizedBox(height: 6),
      pw.Text('Declaration :', style: st(8, b: true)),
      pw.Text(
          'We declare that this proforma shows the actual price of the goods described and that all particulars are true and correct.',
          style: st(7.5)),
      pw.SizedBox(height: 2),
      pw.Text('Terms and Condition :', style: st(8, b: true)),
      pw.Text(
          'In case the payment is delayed more than the credit period, interest @ 18 % will be charged. Payment shall be made exclusively via bank transfer or cheque to the company account specified in the invoice. Please do not make any cash payments to company representatives.',
          style: st(7.5)),
      pw.SizedBox(height: 6),
      pw.Center(child: pw.Text(kJurisdiction, style: st(7, b: true))),
      pw.Center(
          child: pw.Text('This is a Computer Generated Invoice',
              style: st(6.5))),
    ],
  ));
  return doc.save();
}

// Fallback layout: only pw.Text, minimal widgets -> renders even if rich throws.
Future<Uint8List> _simpleProforma(Map<String, dynamic> order,
    Map<String, dynamic> customer, bool isPurchaseOrder, String why) async {
  final doc = pw.Document();
  final items = (order['items'] as List?) ?? [];
  final title = isPurchaseOrder ? 'PURCHASE ORDER' : 'PROFORMA INVOICE';
  final df = DateTime.tryParse(order['transaction_date']?.toString() ?? '') ??
      DateTime.now();
  final dateStr =
      '${df.day.toString().padLeft(2, '0')}/${df.month.toString().padLeft(2, '0')}/${df.year}';
  double total = 0;
  for (final it in items) {
    total += _pdfNum(it['amount']).toDouble();
  }
  final custName =
  _pdfSafe(customer['customer_name'] ?? order['customer'] ?? '');

  pw.TextStyle s(double sz, {bool b = false}) => pw.TextStyle(
      fontSize: sz,
      fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal);

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    build: (context) => [
      pw.Text(kCoName, style: s(16, b: true)),
      pw.Text(_pdfSafe(kCoAddress), style: s(9)),
      pw.Text('GST No : $kCoGST', style: s(9)),
      pw.SizedBox(height: 10),
      pw.Text(title, style: s(13, b: true)),
      pw.SizedBox(height: 8),
      pw.Text('Invoice No : ${_pdfSafe(order['name'])}', style: s(10)),
      pw.Text('Date : $dateStr', style: s(10)),
      pw.SizedBox(height: 8),
      pw.Text('Bill To :', style: s(11, b: true)),
      pw.Text(custName, style: s(11)),
      pw.SizedBox(height: 12),
      pw.Text('Items', style: s(11, b: true)),
      pw.Divider(),
      for (var k = 0; k < items.length; k++)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(
              '${k + 1}. ${_pdfSafe(items[k]['item_name'] ?? items[k]['item_code'])}'
                  '   Qty ${_pdfNum(items[k]['qty'])}'
                  ' x ${_pdfNum(items[k]['rate'])}'
                  ' = INR ${_pdfNum(items[k]['amount']).toStringAsFixed(2)}',
              style: s(10)),
        ),
      pw.Divider(),
      pw.Text('Gross Total : INR ${total.toStringAsFixed(2)}', style: s(12, b: true)),
      pw.SizedBox(height: 6),
      pw.Text('INR ${_amountInWords(total)} Only', style: s(9)),
      pw.SizedBox(height: 16),
      pw.Text("Company's Bank Details", style: s(10, b: true)),
      pw.Text('Bank Name : $kBankName   Branch : $kBankBranch', style: s(9)),
      pw.Text('A/C Number : $kBankAcc   IFSC : $kBankIFSC', style: s(9)),
      pw.Text("Company's PAN : $kCoPAN", style: s(9)),
      pw.SizedBox(height: 10),
      pw.Text(
          'In case the payment is delayed more than the credit period, interest @ 18 % will be charged. '
              'Payment shall be made exclusively via bank transfer or cheque to the company account specified in the invoice.',
          style: s(8)),
      pw.SizedBox(height: 8),
      pw.Text(kJurisdiction, style: s(8, b: true)),
      pw.SizedBox(height: 14),
      pw.Text('For $kCoName', style: s(9)),
      pw.SizedBox(height: 24),
      pw.Text('Authorised Signatory', style: s(9)),
    ],
  ));
  return doc.save();
}

// Build the PDF, save it to a real file, and open it in the device's own
// PDF viewer. This avoids the printing plugin's in-app rasteriser (which
// hangs forever on some devices). Falls back to the OS share sheet.
Future<String?> openProformaPdf({
  required Map<String, dynamic> order,
  required Map<String, dynamic> customer,
  bool isPurchaseOrder = false,
}) async {
  try {
    final bytes = await buildProformaPdf(
        order: order, customer: customer, isPurchaseOrder: isPurchaseOrder);
    final dir = await getTemporaryDirectory();
    final safeName =
    (order['name'] ?? 'doc').toString().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final path = '${dir.path}/Proforma_$safeName.pdf';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    final res = await OpenFilex.open(path, type: 'application/pdf');
    if (res.type != ResultType.done) {
      // Fallback: hand to the OS share sheet (also renders via the OS).
      await Printing.sharePdf(bytes: bytes, filename: 'Proforma_$safeName.pdf');
    }
    return null;
  } catch (e) {
    return '$e';
  }
}

// -------------------- PROFORMA PREVIEW --------------------
