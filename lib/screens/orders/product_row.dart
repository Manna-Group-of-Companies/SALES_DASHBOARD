// One product as it appears while a rep is building an order.
//
// The four families do not share an input: PCTR counts rolls and loose belts,
// CTR counts rolls only, bonding gum counts boxes and rolls, and solution
// counts tins. What they do share is the shape of the row — spec line, minimum
// stock, inputs, then the derived weight and amount — so a rep reads every row
// the same way even though they type into different boxes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/screens/orders/aging_stock_screen.dart'
    show lastSoldLabel;

class ProductRow extends StatefulWidget {
  final OrderLine line;

  /// The item's minimum-stock position, or null when it is not on the list.
  /// The distinction is shown to the rep rather than hidden: "no minimum
  /// stock" and "none left" mean very different things at a counter.
  final MinStock? stock;

  /// False for units that do not run a minimum-stock process at all. Their
  /// rows carry no stock line, rather than one that permanently reads "No
  /// minimum stock" — which would be true but meaningless to them.
  final bool showMinimumStock;

  /// True once the sales manager has approved what this line sells at. The
  /// quantity stays open — the customer can still change their mind about how
  /// much — but the price is no longer the rep's to move.
  final bool rateLocked;

  final VoidCallback onChanged;

  const ProductRow({
    super.key,
    required this.line,
    required this.stock,
    required this.onChanged,
    this.showMinimumStock = true,
    this.rateLocked = false,
  });

  @override
  State<ProductRow> createState() => _ProductRowState();
}

class _ProductRowState extends State<ProductRow> {
  late final TextEditingController _rate;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _rate = TextEditingController(
        text: widget.line.rate > 0 ? trimQty(widget.line.rate) : '');
  }

  /// Collects the packing figures this item was imported without, and writes
  /// them once.
  ///
  /// Only the missing ones are asked for. A figure already on the item is not
  /// offered for editing here at all — it decides what customers are charged,
  /// and a number that can be revised after orders have been priced against it
  /// is one nobody can reconcile later. Corrections go through Desk.
  Future<void> _collectPacking() async {
    final rollCtrl = TextEditingController();
    final beltsCtrl = TextEditingController();
    final litresCtrl = TextEditingController();

    final needsRoll = (p.category == ProductCategory.pctr ||
            p.category == ProductCategory.ctr) &&
        p.weightPerRoll <= 0;
    final needsBelts =
        p.category == ProductCategory.pctr && p.beltsPerRoll <= 0;
    final needsLitres =
        p.category == ProductCategory.vulcanizingSolution && p.packLitres <= 0;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Packing details'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(p.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (needsRoll) ...[
              TextField(
                controller: rollCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Weight of one roll',
                  suffixText: 'kg',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (needsBelts) ...[
              TextField(
                controller: beltsCtrl,
                autofocus: !needsRoll,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Belts per roll',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (needsLitres) ...[
              TextField(
                controller: litresCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Litres per tin',
                  suffixText: 'L',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              'This is what the product is priced by, and it cannot be changed '
              'from the app once saved. Check it before you save.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    final roll = double.tryParse(rollCtrl.text.trim());
    final belts = int.tryParse(beltsCtrl.text.trim());
    final litres = double.tryParse(litresCtrl.text.trim());

    if ((needsRoll && (roll == null || roll <= 0)) ||
        (needsBelts && (belts == null || belts <= 0)) ||
        (needsLitres && (litres == null || litres <= 0))) {
      _snack('Enter every figure before saving.');
      return;
    }

    setState(() => _saving = true);
    try {
      final written = await Api.saveItemPacking(
        itemCode: p.code,
        weightPerRoll: needsRoll ? roll : null,
        beltsPerRoll: needsBelts ? belts : null,
        packLitres: needsLitres ? litres : null,
      );
      // Applied to the in-memory item so the row prices immediately, rather
      // than making the rep leave and come back.
      p.doc.addAll(written);
      widget.onChanged();
      // Another rep can have filled the same item in between this screen
      // loading and this save. Theirs stands, and the rep is told so rather
      // than being left to wonder why the row prices off a different number.
      final kept = (needsRoll && written['custom_weight_per_roll'] != roll) ||
          (needsBelts && written['custom_belts_per_roll'] != belts) ||
          (needsLitres && written['custom_pack_litres'] != litres);
      _snack(kept
          ? 'Someone else filled this in first — their figures are being used.'
          : 'Saved. This cannot be changed from the app.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 5)));

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  OrderLine get line => widget.line;
  Product get p => line.product;

  /// What this row would book against the pool, in the pool's own units.
  /// Whole rolls, kilograms or tins — never the fractional roll that loose
  /// belts create, because belts are booked on their own counter.
  double get _wouldBook => line.reserveQty;

  int get _wouldBookBelts => line.reserveBelts;

  /// The rep's own existing booking is already inside the reserved figures, so
  /// it has to be added back before comparing, or editing a line would look
  /// like an overdraw of itself.
  double get _headroom =>
      (widget.stock?.availableQty ?? 0) + (widget.stock?.myReservedQty ?? 0);

  int get _beltHeadroom =>
      (widget.stock?.availableLooseBelts ?? 0) +
      (widget.stock?.myReservedLooseBelts ?? 0);

  bool get _overBooking {
    if (widget.stock == null) return false;
    return _wouldBook > _headroom + 0.0001 || _wouldBookBelts > _beltHeadroom;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(p.name,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          if (!line.isEmpty)
            Text('Rs ${line.amount.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
        ]),
        const SizedBox(height: 2),
        _specLine(),
        if (widget.showMinimumStock) ...[
          const SizedBox(height: 6),
          _stockLine(),
        ],
        // What the factory has on a run for this item.
        //
        // It also appears on the minimum-stock list, but this is the screen a
        // rep is actually on when a customer asks — and "there are none left"
        // and "there are none left, twenty are being made" are different
        // answers to give somebody standing at the counter. Putting it only
        // one screen away meant the rep had to already suspect it was there.
        if (widget.showMinimumStock &&
            widget.stock?.hasProductionRun == true) ...[
          const SizedBox(height: 4),
          _inProductionLine(widget.stock!),
        ],
        // A minimum-stock item is meant to be fast-moving. One that has stopped
        // selling is drifting towards a write-off, and the rep standing in
        // front of a customer is the only person who can turn that around.
        if (widget.showMinimumStock &&
            widget.stock?.isDeadStockRisk == true) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.trending_down, size: 13, color: Colors.red.shade700),
            const SizedBox(width: 4),
            Expanded(
              child: Text(lastSoldLabel(widget.stock!),
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w500)),
            ),
          ]),
        ],
        if (p.isMisconfigured) ...[
          const SizedBox(height: 6),
          _packingPrompt(),
        ] else ...[
          const SizedBox(height: 8),
          _inputs(),
          const SizedBox(height: 8),
          _rateField(),
          if (!line.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
                // The per-roll figure is shown because that is what ends up on
                // the order line, and a rep who quoted per kg should be able to
                // see the two agree before they submit.
                p.category.isSoldByWeight && p.rollWeight > 0 && line.rate > 0
                    ? '${line.packingNote}   ·   Rs ${trimQty(line.lineRate)}/roll'
                    : line.packingNote,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
          if (_overBooking) ...[
            const SizedBox(height: 6),
            _warning(_wouldBookBelts > _beltHeadroom
                ? 'Only $_beltHeadroom loose belt'
                    '${_beltHeadroom == 1 ? '' : 's'} left in minimum stock.'
                : 'Only ${trimQty(_headroom)} ${p.category.stockUnit} left in '
                    'minimum stock. Reduce the quantity or offer aged stock '
                    'instead.'),
          ],
        ],
      ]),
    );
  }

  // ------------------------------------------------------------- spec ---

  /// The fixed facts about the product, which the rep reads out to the
  /// customer. For PCTR these are averages and are labelled as such, because a
  /// precured roll is cut to length and never weighs exactly the same twice.
  Widget _specLine() {
    final bits = <String>[p.category.shortLabel];
    switch (p.category) {
      case ProductCategory.pctr:
        // Both weights, because a rep sells in both units and each is the
        // number they need to sanity-check a price against.
        if (p.weightPerRoll > 0) {
          bits.add('${trimQty(p.weightPerRoll)} kg/roll');
        }
        if (p.weightPerBelt > 0) {
          bits.add('${trimQty(p.weightPerBelt)} kg/belt');
        }
        if (p.beltsPerRoll > 0) bits.add('${p.beltsPerRoll} belts/roll');
        break;
      case ProductCategory.ctr:
        if (p.weightPerRoll > 0) {
          bits.add('${trimQty(p.weightPerRoll)} kg/roll exact');
        }
        break;
      case ProductCategory.bondingGum:
        bits.add('1 box = $kBgRollsPerBox rolls');
        bits.add('1 roll = ${trimQty(kBgKgPerRoll)} kg');
        break;
      case ProductCategory.vulcanizingSolution:
        if (p.packLitres > 0) bits.add('${trimQty(p.packLitres)} L can');
        break;
      case ProductCategory.other:
        if (p.uom.isNotEmpty) bits.add(p.uom);
        break;
    }
    return Text(bits.join('  ·  '),
        style: const TextStyle(fontSize: 12, color: Colors.black54));
  }

  // ------------------------------------------------------ minimum stock ---

  /// "5 rolls being made" — what production has told everyone is on a run.
  ///
  /// Deliberately not folded into the availability line beside "3 available".
  /// Two numbers in one sentence, one of which can be sold and one of which
  /// cannot, is how a rep ends up promising stock that does not exist. It sits
  /// on its own line, in its own colour, saying it is not on the shelf.
  Widget _inProductionLine(MinStock s) {
    final unit = p.category.stockUnit;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.precision_manufacturing_outlined,
          size: 13, color: Color(0xFF1A56A8)),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
            '${s.describe(s.inProductionQty, s.inProductionBelts, unit)} '
            'being made — not on the shelf yet',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A56A8))),
      ),
    ]);
  }

  Widget _stockLine() {
    final s = widget.stock;
    if (s == null) {
      return const Text('No minimum stock',
          style: TextStyle(
              fontSize: 12,
              color: Colors.black45,
              fontStyle: FontStyle.italic));
    }
    final avail = s.availableQty;
    final belts = s.availableLooseBelts;
    final unit = p.category.stockUnit;
    // Below the minimum is the state worth colouring: the shelf is meant to
    // hold at least that much, and dropping under it is what replenishment
    // exists to catch. Above it is simply healthy.
    final belowMinimum = s.minimumQty > 0 && avail < s.minimumQty;
    final colour = (avail <= 0 && belts <= 0)
        ? Colors.red
        : (belowMinimum ? Colors.orange.shade800 : Colors.green);
    // Belts are only mentioned when there are some — on CTR, bonding gum and
    // solution the counter is always zero and saying so would be noise.
    final beltSuffix = belts > 0 ? ' + $belts loose belt${belts == 1 ? '' : 's'}' : '';
    return Row(children: [
      Icon(Icons.inventory_2_outlined, size: 14, color: colour),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          (avail <= 0 && belts <= 0)
              ? 'None left (minimum ${trimQty(s.minimumQty)} $unit)'
              // Available first, because that is what the rep can sell. The
              // minimum only earns a mention when the shelf has fallen under
              // it — quoting a threshold nobody is near is noise.
              : '${trimQty(avail)} $unit$beltSuffix available'
                  '${belowMinimum ? '  ·  below minimum ${trimQty(s.minimumQty)}' : ''}'
                  '${s.reservedQty > 0 ? '  ·  ${trimQty(s.reservedQty)} booked' : ''}',
          style: TextStyle(
              fontSize: 12, color: colour, fontWeight: FontWeight.w500),
        ),
      ),
    ]);
  }

  // ----------------------------------------------------------- inputs ---

  Widget _inputs() {
    switch (p.category) {
      case ProductCategory.pctr:
        return Row(children: [
          Expanded(
              child: _counter('Rolls', line.rolls, (v) {
            line.rolls = v;
            widget.onChanged();
          })),
          const SizedBox(width: 10),
          Expanded(
              child: _counter('Loose belts', line.looseBelts, (v) {
            line.looseBelts = v;
            widget.onChanged();
          })),
        ]);
      case ProductCategory.ctr:
        // No belt entry: CTR leaves the factory as whole fixed-weight rolls,
        // so a half roll is not a thing a rep can sell.
        return _counter('Rolls', line.rolls, (v) {
          line.rolls = v;
          widget.onChanged();
        });
      case ProductCategory.bondingGum:
        return Row(children: [
          Expanded(
              child: _counter('Boxes', line.boxes, (v) {
            line.boxes = v;
            widget.onChanged();
          })),
          const SizedBox(width: 10),
          Expanded(
              child: _counter('Loose rolls', line.rolls, (v) {
            line.rolls = v;
            widget.onChanged();
          })),
        ]);
      case ProductCategory.vulcanizingSolution:
        return _counter('Cans', line.cans, (v) {
          line.cans = v;
          widget.onChanged();
        });
      case ProductCategory.other:
        return _counter('Quantity', line.rolls, (v) {
          line.rolls = v;
          widget.onChanged();
        });
    }
  }

  Widget _counter(String label, int value, ValueChanged<int> onSet) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        InkWell(
          onTap: value > 0 ? () => onSet(value - 1) : null,
          child: Icon(Icons.remove_circle_outline,
              size: 22, color: value > 0 ? Colors.black87 : Colors.black26),
        ),
        Text('$value',
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        InkWell(
          onTap: () => onSet(value + 1),
          child: const Icon(Icons.add_circle_outline, size: 22),
        ),
      ]),
    );
  }

  /// Rate is never prefilled from `standard_rate`. Field pricing is negotiated
  /// per customer, and a prefilled number is one a tired rep will accept.
  ///
  /// Once the manager has approved it the field goes read-only rather than
  /// disappearing — the rep still needs to see what was agreed while they are
  /// talking to the customer.
  Widget _rateField() {
    return TextField(
      controller: _rate,
      readOnly: widget.rateLocked,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))
      ],
      decoration: InputDecoration(
        labelText: 'Rate per ${p.category.rateUnit}',
        prefixText: 'Rs ',
        border: const OutlineInputBorder(),
        isDense: true,
        filled: widget.rateLocked,
        fillColor: const Color(0xFFF0F0F0),
        suffixIcon: widget.rateLocked
            ? const Icon(Icons.lock_outline, size: 16, color: Colors.black45)
            : null,
        errorText: line.needsRate ? 'Enter a rate' : null,
        helperText: widget.rateLocked
            ? 'Approved by your manager — ask them to reopen it'
            : ((p.doc['standard_rate'] is num &&
                    (p.doc['standard_rate'] as num) > 0)
                ? 'List rate Rs ${trimQty((p.doc['standard_rate'] as num).toDouble())}'
                : null),
        helperStyle: const TextStyle(fontSize: 11),
      ),
      onChanged: (v) {
        if (widget.rateLocked) return;
        line.rate = double.tryParse(v) ?? 0;
        widget.onChanged();
      },
    );
  }

  /// What an incomplete item offers instead of a dead end.
  ///
  /// The rep is standing in front of the product; the office is not. Asking
  /// them to wait for a master to be filled in loses the sale, so they fill it
  /// in. It still cannot be ordered until they do — the arithmetic has no
  /// answer without it — but the block is now something they can clear.
  Widget _packingPrompt() => Material(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _saving ? null : _collectPacking,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.edit_note, size: 18, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Packing details needed — tap to add',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange.shade900)),
                      const SizedBox(height: 2),
                      Text(_missingLabel,
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.orange.shade900)),
                    ]),
              ),
              if (_saving)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
        ),
      );

  /// Which figures this family still owes, in the rep's words.
  String get _missingLabel {
    final p = widget.line.product;
    final missing = <String>[
      if (p.category == ProductCategory.pctr ||
          p.category == ProductCategory.ctr)
        if (p.weightPerRoll <= 0) 'weight of one roll',
      if (p.category == ProductCategory.pctr)
        if (p.beltsPerRoll <= 0) 'belts per roll',
      if (p.category == ProductCategory.vulcanizingSolution)
        if (p.packLitres <= 0) 'litres per tin',
    ];
    return 'Needs the ${missing.join(' and the ')}.';
  }

  Widget _warning(String text) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: const Color(0xFFFFF3E0),
            borderRadius: BorderRadius.circular(6)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: Colors.orange.shade800),
          const SizedBox(width: 6),
          Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12, color: Colors.orange.shade900))),
        ]),
      );
}
