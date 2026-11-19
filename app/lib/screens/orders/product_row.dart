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
import 'package:manna_field_sales/models/sap_rates.dart';
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

  /// Manna Treads' SAP rate for this item and this customer or lead, or null
  /// when SAP has none. When there is one it IS the price (the user, 26 Sep
  /// 2026): the screen has already put it in the box, and the box is locked.
  /// An item with no [sapRate] is priced by hand as before.
  final SapRate? sapRate;

  /// True on a lead order, where [sapRate] is always the list price. Changes
  /// only what the line under the box says.
  final bool leadOrder;

  /// True where the phone has no SAP price to give (the user, 11 Nov 2026): a
  /// rep of a unit other than Manna Treads, whose parties have no Manna Treads
  /// price, or an item not priced per kg. The rep types the rate there, as
  /// before 10 Nov. Everywhere else the rate is SAP's and cannot be typed.
  final bool typedRate;

  /// True when SAP's price could not be read for want of a signal: the line
  /// can be kept on the phone and takes SAP's price when it is sent.
  final bool sapPriceLater;

  final VoidCallback onChanged;

  const ProductRow({
    super.key,
    required this.line,
    required this.stock,
    required this.onChanged,
    this.showMinimumStock = true,
    this.rateLocked = false,
    this.sapRate,
    this.leadOrder = false,
    this.typedRate = false,
    this.sapPriceLater = false,
  });

  @override
  State<ProductRow> createState() => _ProductRowState();
}

class _ProductRowState extends State<ProductRow> {
  late final TextEditingController _rate;
  late final TextEditingController _kilos;
  final FocusNode _rateFocus = FocusNode();
  bool _saving = false;

  /// Which of [_units] the stepper moves. Only bonding gum has a choice.
  int _unitIndex = 0;

  @override
  void initState() {
    super.initState();
    _rate = TextEditingController(
        text: widget.line.rate > 0 ? trimQty(widget.line.rate) : '');
    _kilos = TextEditingController(
        text: widget.line.kilos > 0 ? trimQty(widget.line.kilos) : '');
    // An order opened for editing with loose rolls and no boxes starts on the
    // unit that has something in it.
    if (widget.line.product.category == ProductCategory.bondingGum &&
        widget.line.boxes == 0 &&
        widget.line.rolls > 0) {
      _unitIndex = 1;
    }
  }

  /// Collects the packing figures this item was imported without, and writes
  /// them once.
  ///
  /// Only the missing ones are asked for. A figure already on the item is not
  /// offered for editing here at all — it decides what customers are charged,
  /// and a number that can be revised after orders have been priced against it
  /// is one nobody can reconcile later. Corrections go through Desk.
  ///
  /// What is typed here is final (11 Oct 2026): the next stock sync writes the
  /// roll weight and belts per roll into SAP's two UDFs, where SAP had none.
  /// Litres per tin has no UDF in SAP and stays in ERPNext.
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
            Text(
              'Cannot be changed after saving. Check it first.',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
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
      final wasByKg = p.soldByKg;
      final kilosBefore = line.kilos;
      // Applied to the in-memory item so the row prices immediately, rather
      // than making the rep leave and come back. A save kept on the phone
      // that could not read the item first comes back empty: the typed figures
      // stand on the row until it is sent.
      p.doc.addAll({
        if (needsRoll && written['custom_weight_per_roll'] == null)
          'custom_weight_per_roll': roll,
        if (needsBelts && written['custom_belts_per_roll'] == null)
          'custom_belts_per_roll': belts,
        if (needsLitres && written['custom_pack_litres'] == null)
          'custom_pack_litres': litres,
        ...written,
      });
      // Another rep can have filled the same item in between this screen
      // loading and this save. Theirs stands, and the rep is told so rather
      // than being left to wonder why the row prices off a different number.
      final kept = (needsRoll &&
              written['custom_weight_per_roll'] != null &&
              written['custom_weight_per_roll'] != roll) ||
          (needsBelts &&
              written['custom_belts_per_roll'] != null &&
              written['custom_belts_per_roll'] != belts) ||
          (needsLitres &&
              written['custom_pack_litres'] != null &&
              written['custom_pack_litres'] != litres);
      final switched = wasByKg && !p.soldByKg
          ? _switchToRolls(kilosBefore)
          : '';
      widget.onChanged();
      _snack(kept
          ? 'Someone else filled this in first — their figures are being used.$switched'
          : (needsRoll || needsBelts)
              ? 'Saved. It goes into SAP with the next stock sync.$switched'
              : 'Saved. This cannot be changed from the app.');
    } catch (e) {
      _snack(humanError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Hot rubber that now has a roll weight is counted in rolls. Kilos already
  /// typed become the nearest whole number of rolls, at least one, and the
  /// rep is told what they became so they can check the count with the
  /// customer. Returns that sentence, or '' when nothing was typed.
  String _switchToRolls(double kilos) {
    _kilos.clear();
    line.kilos = 0;
    if (kilos <= 0) return ' Now ordered in rolls.';
    line.rolls = rollsForKilos(kilos, p.weightPerRoll);
    return ' Now in rolls: ${trimQty(kilos)} kg became ${line.rolls} '
        'roll${line.rolls == 1 ? '' : 's'} '
        '(${trimQty(line.rolls * p.weightPerRoll)} kg). Check the count.';
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 5)));

  @override
  void dispose() {
    _rate.dispose();
    _kilos.dispose();
    _rateFocus.dispose();
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

  /// Laid out the way the user drew it (19 Nov 2026): the name in bold with
  /// ADD beside it, the packing facts under it, then "Price: ₹ 315 / kg" as
  /// plain text and the stock line. ADD turns into a − / qty / + stepper once
  /// the item is on the order. Only the layout changed — the price is still
  /// SAP's and locked, typed only where the phone has no SAP price.
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    // A white card per product, as the app's other cards are (radius 16,
    // hairline border).
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFECECEC)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Always one line (19 Nov 2026, the user's request): a long name is
        // shrunk to fit the card rather than wrapped or cut off, so the whole
        // name is still there to read.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(p.name,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                  height: 1.3,
                  color: Colors.black87)),
        ),
        const SizedBox(height: 4),
        _specLine(),
        if (!p.isMisconfigured) ...[
          const SizedBox(height: 10),
          // Price on the left, ADD (or the stepper) on the right of it.
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: _priceLine(primary)),
            if (!_byKilo) ...[
              const SizedBox(width: 10),
              _quantityControl(primary),
            ],
          ]),
          // Hot rubber with no roll weight is ordered in kilos (14 Nov 2026):
          // the kilos box and "Add roll weight" stand where ADD would.
          if (_byKilo) ...[
            const SizedBox(height: 10),
            _kilosField(),
            _addRollWeight(),
          ],
        ],
        // An item with no stock record shows no line at all (19 Nov 2026,
        // the user's drawing): "No minimum stock" on almost every card was
        // noise. An item that has a record still says what is available, or
        // "None left" — which is why silence can only mean "no record".
        if (widget.showMinimumStock && widget.stock != null) ...[
          const SizedBox(height: 8),
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
          const SizedBox(height: 8),
          _packingPrompt(),
        ] else ...[
          if (!line.isEmpty) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Text(
                    // The per-roll figure is shown because that is what ends
                    // up on the order line, and a rep who quoted per kg should
                    // be able to see the two agree before they submit.
                    p.category.isSoldByWeight &&
                            p.rollWeight > 0 &&
                            line.rate > 0
                        ? '${line.packingNote}   ·   Rs ${trimQty(line.lineRate)}/roll'
                        : line.packingNote,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.black54)),
              ),
              const SizedBox(width: 8),
              Text('Rs ${line.amount.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: primary)),
            ]),
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
        } else {
          bits.add('Sold by kg');
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
        style: const TextStyle(fontSize: 13.5, color: Colors.black54));
  }

  // ------------------------------------------------------ minimum stock ---

  Widget _stockLine() {
    final s = widget.stock;
    if (s == null) {
      return const Text('No minimum stock',
          style: TextStyle(
              fontSize: 13.5,
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
                  fontSize: 13.5,
                  color: Colors.black45,
                  fontStyle: FontStyle.italic)),
        ),
      ]);
    }
    final avail = s.availableQty;
    final unit = p.category.stockUnit;
    // Empty is the only state worth colouring now. "Below the minimum" was
    // orange here until 21 August 2026, but the minimum is management's figure
    // and is no longer shown to reps — a colour keyed to a number the rep
    // cannot see is a warning they have no way to read.
    final colour = avail <= 0 ? Colors.red : Colors.green;

    // Nothing is shown about what other reps are holding. There is no such
    // figure any more: SAP has already taken every open order off this number,
    // so "12 booked" would be describing a deduction that has already
    // happened and inviting the rep to subtract it twice.
    return Row(children: [
      Icon(Icons.inventory_2_outlined, size: 14, color: colour),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          avail <= 0
              ? 'None left'
              : '${trimQty(avail)} $unit available',
          style: TextStyle(
              fontSize: 13.5, color: colour, fontWeight: FontWeight.w500),
        ),
      ),
    ]);
  }

  // ----------------------------------------------------------- inputs ---

  /// What this family is counted in. Most have one unit; bonding gum has two
  /// (boxes and loose rolls), and the chips over the stepper pick which one
  /// the stepper moves.
  List<_Unit> get _units {
    switch (p.category) {
      // Rolls only (10 Nov 2026): loose belts are no longer taken on an order.
      case ProductCategory.pctr:
      case ProductCategory.ctr:
        return [_Unit('Rolls', () => line.rolls, (v) => line.rolls = v)];
      case ProductCategory.bondingGum:
        return [
          _Unit('Boxes', () => line.boxes, (v) => line.boxes = v),
          // "Rolls" on the chip, which has little room; the typing dialog
          // still says loose rolls.
          _Unit('Loose rolls', () => line.rolls, (v) => line.rolls = v,
              chip: 'Rolls'),
        ];
      case ProductCategory.vulcanizingSolution:
        return [_Unit('Cans', () => line.cans, (v) => line.cans = v)];
      case ProductCategory.other:
        return [_Unit('Quantity', () => line.rolls, (v) => line.rolls = v)];
    }
  }

  /// Hot rubber with no roll weight: the kilos, typed (14 Nov 2026).
  Widget _kilosField() => TextField(
        controller: _kilos,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,3}'))
        ],
        decoration: const InputDecoration(
          labelText: 'Kilos',
          suffixText: 'kg',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (v) {
          line.kilos = double.tryParse(v) ?? 0;
          widget.onChanged();
        },
      );

  /// Optional, never in the way (18 Nov 2026, the user: SAP has no roll weight
  /// for most hot rubber, and a rep who knows it adds it here). Saving it
  /// turns the row into a Rolls counter. Ordering in kilos needs none of it -
  /// the blocking prompt went on 14 Nov 2026 for exactly that reason.
  Widget _addRollWeight() => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _saving ? null : _collectPacking,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 12.5),
          ),
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.scale_outlined, size: 16),
          label: const Text('Add roll weight'),
        ),
      );

  bool get _byKilo => p.category == ProductCategory.ctr && p.soldByKg;

  bool get _typesRate =>
      widget.typedRate && !widget.rateLocked && widget.sapRate == null;

  void _set(_Unit u, int v) {
    setState(() => u.set(v < 0 ? 0 : v));
    widget.onChanged();
  }

  /// ADD puts one of the selected unit on the order. Where the rep prices the
  /// line themselves, the rate box takes the focus straight away, because a
  /// line with no rate cannot be sent.
  void _add() {
    final units = _units;
    _set(units[_unitIndex.clamp(0, units.length - 1)], 1);
    if (_typesRate && line.rate <= 0) _rateFocus.requestFocus();
  }

  Widget _quantityControl(Color primary) {
    if (line.isEmpty) {
      return SizedBox(
        width: 110,
        height: 44,
        child: OutlinedButton(
          onPressed: _add,
          style: OutlinedButton.styleFrom(
            foregroundColor: primary,
            side: BorderSide(color: primary, width: 1.4),
            padding: EdgeInsets.zero,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Text('ADD',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5)),
            SizedBox(width: 4),
            Icon(Icons.add, size: 18),
          ]),
        ),
      );
    }
    final units = _units;
    final i = _unitIndex.clamp(0, units.length - 1);
    return SizedBox(
      width: 116,
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var k = 0; k < units.length; k++)
              _unitChip(units[k], k == i, units.length > 1,
                  () => setState(() => _unitIndex = k), primary),
          ],
        ),
        const SizedBox(height: 6),
        _stepper(units[i], primary),
      ]),
    );
  }

  Widget _unitChip(_Unit u, bool selected, bool showCount, VoidCallback onTap,
      Color primary) {
    final n = u.get();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? primary.withValues(alpha: 0.10) : null,
          border: Border.all(
              color: selected ? primary : const Color(0xFFDADADA)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(u.chip,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                  fontWeight: FontWeight.w600,
                    color: selected ? primary : Colors.black54)),
          ),
          // With two units the one not under the stepper still shows how many
          // are on the order, so nothing typed is out of sight.
          if (showCount && n > 0) ...[
            const SizedBox(width: 4),
            Text('$n',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87)),
          ],
        ]),
      ),
    );
  }

  Widget _stepper(_Unit u, Color primary) {
    final v = u.get();
    Widget button(IconData icon, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 38,
            child: Icon(icon,
                size: 18, color: onTap == null ? Colors.black26 : primary),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFDADADA)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        button(Icons.remove, v > 0 ? () => _set(u, v - 1) : null),
        InkWell(
          onTap: () => _typeQty(u),
          child: Container(
            width: 44,
            height: 38,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              border: Border.symmetric(
                  vertical: BorderSide(color: Color(0xFFDADADA))),
            ),
            child: Text('$v',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        button(Icons.add, () => _set(u, v + 1)),
      ]),
    );
  }

  /// Tapping the number types it, for the order of forty rolls that nobody
  /// wants to reach by pressing + forty times.
  Future<void> _typeQty(_Unit u) async {
    final text = '${u.get()}';
    final ctrl = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(u.label),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (t) => Navigator.pop(ctx, int.tryParse(t.trim()) ?? 0),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? 0),
              child: const Text('OK')),
        ],
      ),
    );
    if (v == null || !mounted) return;
    _set(u, v);
  }

  /// The rate is SAP's, never typed (10 Nov 2026): the box shows Manna
  /// Treads' SAP rate for this customer and cannot be edited. An item SAP has
  /// no rate for cannot be ordered until the office prices it in SAP. Once the
  /// manager has approved the order it stays shown, read-only.
  ///
  /// Except where the phone has no SAP price to give at all ([typedRate],
  /// 11 Nov 2026): there the rep types it, never prefilled — field pricing is
  /// negotiated per customer, and a prefilled number is one a tired rep will
  /// accept.
  ///
  /// Shown as plain text, "Price: ₹ 315 / kg" (19 Nov 2026): a locked box
  /// looked like something to type into. Only a typed rate gets a box.
  Widget _priceLine(Color primary) {
    final sap = widget.sapRate;
    final unit = p.category.rateUnit;
    final typed = _typesRate;
    final later =
        widget.sapPriceLater && !typed && !widget.rateLocked && sap == null;
    final noPrice =
        !typed && !later && !widget.rateLocked && sap == null && line.rate <= 0;

    const label = TextStyle(fontSize: 16, color: Colors.black54);
    // One wrapping line of text rather than a row of boxes, so a long price
    // on a small phone moves to a second line instead of overflowing.
    final Widget main;
    if (typed) {
      main = TextField(
        controller: _rate,
        focusNode: _rateFocus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))
        ],
        style: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700, color: primary),
        decoration: InputDecoration(
          labelText: 'Price',
          prefixText: '₹ ',
          suffixText: '/ $unit',
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          errorText: line.needsRate ? 'Enter a rate' : null,
        ),
        onChanged: (v) {
          line.rate = double.tryParse(v) ?? 0;
          widget.onChanged();
        },
      );
    } else {
      final TextSpan value;
      if (later) {
        value = const TextSpan(
            text: 'SAP price when sent',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black54));
      } else if (noPrice) {
        value = TextSpan(
            text: 'No price in SAP',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.red.shade700));
      } else {
        value = TextSpan(children: [
          TextSpan(
              text: '₹ ${trimQty(line.rate)}',
              style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w800, color: primary)),
          TextSpan(text: ' / $unit', style: label),
        ]);
      }
      main = Text.rich(
          TextSpan(children: [const TextSpan(text: 'Price:  ', style: label), value]));
    }

    // What the price is, said in a few words: the long "Set in SAP — ask the
    // office" line is gone with the box it sat under.
    String? dealerNote(SapRate s) {
      if (!s.isDealerPrice) return null;
      final l = s.list;
      return (l != null && l > 0 && (l - s.rate).abs() > 0.004)
          ? "Dealer's price · list ₹ ${trimQty(l)}"
          : "Dealer's price";
    }

    final String? note = widget.rateLocked
        ? 'Approved by your manager'
        : sap != null
            ? (widget.leadOrder ? 'Lead order: list rate' : dealerNote(sap))
            : later
                ? 'Price from SAP when it is sent.'
                : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      main,
      if (note != null) ...[
        const SizedBox(height: 2),
        Text(note,
            style: const TextStyle(fontSize: 12, color: Colors.black45)),
      ],
    ]);
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
      if (p.category == ProductCategory.pctr)
        if (p.weightPerRoll <= 0) 'weight of one roll',
      if (p.category == ProductCategory.pctr)
        if (p.beltsPerRoll <= 0) 'belts per roll',
      if (p.category == ProductCategory.vulcanizingSolution)
        if (p.packLitres <= 0) 'litres per tin',
    ];
    return 'Needs the ${missing.join(' and the ')}.';
  }

}

/// One countable unit of a line — rolls, boxes, cans — read and written
/// straight through to the [OrderLine], so the row keeps no second copy of
/// the quantity to drift out of step.
class _Unit {
  final String label;
  final int Function() get;
  final void Function(int) set;

  /// The shorter name on the chip, where there is little room.
  final String chip;

  const _Unit(this.label, this.get, this.set, {String? chip})
      : chip = chip ?? label;
}
