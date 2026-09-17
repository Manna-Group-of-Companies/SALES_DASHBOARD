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
import 'package:manna_field_sales/core/pool_allocation.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/product_category.dart';
import 'package:manna_field_sales/services/api.dart';

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

  /// What SAP says is free to promise. Nothing is added back for this rep's
  /// own line: there is no hold to add back, and an order still being edited
  /// has not reached SAP to be counted against.
  double get _headroom {
    final s = widget.stock;
    if (s == null) return 0;
    return s.availableQty;
  }

  /// Loose belts free to this line, BEFORE any roll is opened for it.
  ///
  /// Not the belt ceiling: [_allocation] is what decides how many belts the
  /// pool can actually serve, because a whole roll can be opened to cover
  /// them. See core/pool_allocation.dart.
  int get _beltHeadroom {
    final s = widget.stock;
    if (s == null) return 0;
    return s.availableLooseBelts;
  }

  /// How this line divides between the pool and production.
  ///
  /// Rolls and belts draw on the SAME shelf, so this is one decision and not
  /// two clamps — a belt asked for against a pool of whole rolls opens one
  /// rather than going to production, which is what it used to do while 48
  /// rolls sat on the shelf.
  PoolAllocation get _allocation => allocateFromPool(
        wantRolls: _wouldBook,
        wantBelts: _wouldBookBelts,
        poolRolls: _headroom,
        poolBelts: _beltHeadroom,
        beltsPerRoll: widget.stock?.beltsPerRoll ?? 0,
      );

  /// True when this line asks for more than the pool it draws on can cover.
  ///
  /// Not an error. Fifteen rolls against a pool of ten is an order for
  /// fifteen — ten come off the shelf and five are made. Refusing it was the
  /// bug: a customer wanting more than the minimum stock is a customer worth
  /// having, and the rep was being told to reduce the order.
  bool get _splitsWithProduction {
    if (widget.stock == null) return false;
    return _allocation.splits;
  }

  /// What the pool covers and what has to be made, said before the rep sends
  /// it — so the split is something they told the customer, not something the
  /// customer discovers when half the order arrives later.
  Widget _splitLine() {
    final unit = p.category.stockUnit;
    final a = _allocation;
    final fromPool = a.rolls;
    final made = a.shortRolls;
    final beltsFromPool = a.belts;
    final beltsMade = a.shortBelts;

    // Always the shelf now. A rep cannot draw on a replenishment run.
    const source = 'minimum stock';
    // Nothing from the pool is not a split, and calling it one would have the
    // rep telling a customer half of it is in stock.
    final nothingFromPool = fromPool <= 0 && beltsFromPool <= 0;
    final parts = nothingFromPool
        ? const <String>[]
        : <String>[
            if (fromPool > 0) '${trimQty(fromPool)} $unit from $source',
            if (beltsFromPool > 0) '$beltsFromPool belts from $source',
            if (made > 0) '${trimQty(made)} $unit made to order',
            if (beltsMade > 0) '$beltsMade belts made to order',
          ];

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: const Color(0xFFF3E8FF),
          borderRadius: BorderRadius.circular(6)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.call_split, size: 15, color: Colors.deepPurple),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
              parts.isEmpty
                  ? 'This whole line will be made to order.'
                  : 'Split: ${parts.join(', ')}.',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.deepPurple)),
        ),
      ]),
    );
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
        /*
         * Nothing about a replenishment run is shown to a rep any more.
         *
         * A run raised to refill the minimum-stock pool goes into COMPANY
         * stock: production make it, the stock person receives it, and it
         * appears on the shelf as a batch like any other intake. Until that
         * happens it is not stock anybody can sell, and telling a rep about it
         * only invited them to promise a customer goods that were still in the
         * press with no date attached.
         *
         * Production against a specific order is a different flow and is still
         * shown — on that order's own lines, where it belongs, with its stage.
         *
         * The claim-out-of-a-run switch went with it, 18 Aug 2026. A rep never
         * touches a replenishment run now: either the goods are on the shelf,
         * or production is raised against their order and dispatched to the
         * customer.
         */
        // A "drifting towards dead stock" warning stood here until 21 August
        // 2026, telling the rep how long it had been since the item last sold.
        // Removed with the rest of the dead-stock feature: how old stock is, is
        // not a rep's decision to make in front of a customer.
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
          if (_splitsWithProduction) ...[
            const SizedBox(height: 6),
            _splitLine(),
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

  Widget _stockLine() {
    final s = widget.stock;
    if (s == null) {
      return const Text('No minimum stock',
          style: TextStyle(
              fontSize: 12,
              color: Colors.black45,
              fontStyle: FontStyle.italic));
    }
    // No weight-per-roll or belts-per-roll on the item master, so SAP's
    // kilograms cannot be turned into rolls. Said plainly rather than shown as
    // a zero: "we have not set this item up" and "we are out" want different
    // things doing about them, and only one of them is the office's problem.
    if (!s.weightsKnown) {
      return const Row(children: [
        Icon(Icons.help_outline, size: 14, color: Colors.black45),
        SizedBox(width: 4),
        Expanded(
          child: Text('Stock not set up for this item',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.black45,
                  fontStyle: FontStyle.italic)),
        ),
      ]);
    }
    final avail = s.availableQty;
    final belts = s.availableLooseBelts;
    final unit = p.category.stockUnit;
    // Empty is the only state worth colouring now. "Below the minimum" was
    // orange here until 21 August 2026, but the minimum is management's figure
    // and is no longer shown to reps — a colour keyed to a number the rep
    // cannot see is a warning they have no way to read.
    final colour = (avail <= 0 && belts <= 0) ? Colors.red : Colors.green;
    // Belts are only mentioned when there are some — on CTR, bonding gum and
    // solution the counter is always zero and saying so would be noise.
    final beltSuffix = belts > 0 ? ' + $belts loose belt${belts == 1 ? '' : 's'}' : '';

    // Nothing is shown about what other reps are holding. There is no such
    // figure any more: SAP has already taken every open order off this number,
    // so "12 booked" would be describing a deduction that has already
    // happened and inviting the rep to subtract it twice.
    return Row(children: [
      Icon(Icons.inventory_2_outlined, size: 14, color: colour),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          (avail <= 0 && belts <= 0)
              ? 'None left'
              : '${trimQty(avail)} $unit$beltSuffix available',
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

}
