
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'package:manna_field_sales/pdf/proforma_pdf.dart';

class ProformaPreviewScreen extends StatelessWidget {
  final Map<String, dynamic> order;
  final Map<String, dynamic> customer;
  final bool isPurchaseOrder;
  const ProformaPreviewScreen(
      {super.key,
        required this.order,
        required this.customer,
        this.isPurchaseOrder = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(isPurchaseOrder ? 'Purchase Order' : 'Proforma Invoice')),
      body: PdfPreview(
        build: (format) => buildProformaPdf(
            order: order, customer: customer, isPurchaseOrder: isPurchaseOrder),
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        pdfFileName: 'Proforma_${order['name'] ?? 'doc'}.pdf',
        loadingWidget: const Center(child: CircularProgressIndicator()),
        useActions: true,
      ),
    );
  }
}

// -------------------- ORDER DETAIL --------------------
