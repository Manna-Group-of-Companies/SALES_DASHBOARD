import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/pdf/proforma_pdf.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/info_box.dart';

class LeadOrderDetailScreen extends StatefulWidget {
  final String orderName;
  final Map<String, dynamic> lead;
  const LeadOrderDetailScreen(
      {super.key, required this.orderName, required this.lead});
  @override
  State<LeadOrderDetailScreen> createState() => _LeadOrderDetailScreenState();
}

class _LeadOrderDetailScreenState extends State<LeadOrderDetailScreen> {
  late Future<void> _init;
  Map<String, dynamic> _order = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _load();
  }

  Future<void> _load() async {
    _order = await Api.getLeadOrder(widget.orderName);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _proforma({required bool asPO}) async {
    final synthCust = {
      'customer_name': widget.lead['lead_name'] ?? _order['lead_name'],
      'territory': widget.lead['territory'],
      'custom_phone': widget.lead['mobile_no'],
    };
    final synthOrder = {
      'name': _order['name'],
      'transaction_date': _order['order_date'],
      'customer': _order['lead_name'],
      'items': _order['items'] ?? [],
    };
    if (!mounted) return;
    setState(() => _busy = true);
    final err = await openProformaPdf(
        order: synthOrder, customer: synthCust, isPurchaseOrder: asPO);
    if (mounted) setState(() => _busy = false);
    if (err != null && mounted) _snack('Proforma error: $err');
  }

  Future<void> _scanPO() async {
    final shot = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 70);
    if (shot == null) return;
    final poNo = await _askPo();
    setState(() => _busy = true);
    try {
      await Api.uploadLeadOrderPO(
          name: _order['name'] as String,
          filePath: shot.path,
          poNumber: poNo);
      _order['status'] = 'PO Uploaded';
      _snack('Signed PO uploaded ✓ — awaiting manager PO approval.');
      setState(() {});
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPo() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('PO Number (optional)'),
          content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(hintText: 'e.g. 192')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('Skip')),
            FilledButton(
                onPressed: () => Navigator.pop(context, ctrl.text),
                child: const Text('OK')),
          ],
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Lead Order ${widget.orderName}')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final status = '${_order['status'] ?? ''}';
          final items = (_order['items'] as List?) ?? [];
          final total = items.fold<double>(
              0, (s, it) => s + (((it['amount'] ?? 0) as num).toDouble()));
          final approved = status == 'Approved' ||
              status == 'PO Uploaded' ||
              status == 'PO Approved - Ready for SAP';
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(widget.lead['lead_name'] ?? _order['lead_name'] ?? '',
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                'Total: Rs ${total.toStringAsFixed(2)}  ·  ${items.length} item(s)'),
            const SizedBox(height: 12),
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: const Color(0xFFF1F3F4),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.flag, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Status: $status',
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                ])),
            const Divider(height: 28),
            if (status == 'Pending Approval')
              const InfoBox(
                  icon: Icons.hourglass_top,
                  color: Colors.orange,
                  text:
                  'Awaiting manager order approval. Once approved, you can send the proforma.'),
            if (status == 'Rejected')
              const InfoBox(
                  icon: Icons.cancel,
                  color: Colors.red,
                  text: 'This lead order was rejected by the manager.'),
            if (approved) ...[
              const Text('1 · Proforma',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : () => _proforma(asPO: false),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text('Generate & Send Proforma')),
              ),
              const SizedBox(height: 20),
              const Text('2 · Customer Purchase Order',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  'Lead signs the proforma and returns it. Scan the signed copy to upload.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              if (status == 'PO Approved - Ready for SAP')
                const InfoBox(
                    icon: Icons.check_circle,
                    color: Colors.green,
                    text:
                    'PO approved — ready to push to SAP (creates the customer).')
              else
                FilledButton.icon(
                  style:
                  FilledButton.styleFrom(backgroundColor: Colors.indigo),
                  onPressed: _busy ? null : _scanPO,
                  icon: const Icon(Icons.document_scanner),
                  label: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(status == 'PO Uploaded'
                          ? 'Re-scan Signed PO'
                          : 'Scan & Upload Signed PO')),
                ),
            ],
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: CircularProgressIndicator())),
          ]);
        },
      ),
    );
  }
}

// -------------------- COMPLAINT --------------------
