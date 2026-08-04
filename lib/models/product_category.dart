// The four things Manna sells, and the arithmetic each one needs before it can
// become a Sales Order line.
//
// THE UNIT PROBLEM
//
// Tread rubber is stocked and counted in rolls, but it is *priced* by the
// kilogram — the rep negotiates a rate per kg and the customer is billed on
// weight. ERPNext has only one `qty` and one `rate` on a line and multiplies
// them, so both cannot be stored as typed.
//
// What is stored is the roll count and a per-roll rate derived from the average
// weight:
//
//     qty   = rolls                       (the Item's stock UOM is Roll)
//     rate  = ratePerKg x weightPerRoll    (so qty x rate is the real amount)
//
// The per-kg rate the rep actually quoted is kept alongside in
// `custom_rate_per_kg`, and the derived weight in `custom_total_weight`, so the
// proforma can show the customer the numbers they agreed to rather than the
// ones ERPNext needed.
//
// Loose belts ride along as a fraction of a roll. A quarter of a roll is a
// quarter of its weight, so the arithmetic stays exact and the amount comes out
// the same as pricing the belts by weight directly.

import 'package:manna_field_sales/core/constants.dart';

/// Which product family an Item belongs to. Read off the Item's `item_group`,
/// so the product import decides this and the app never guesses from a code.
enum ProductCategory {
  pctr,
  ctr,
  bondingGum,
  vulcanizingSolution,

  /// Anything whose item group we do not recognise. Falls back to the plain
  /// qty-and-rate row, which is what the order screen did for everything
  /// before the product families existed.
  other,
}

ProductCategory categoryOfGroup(String? itemGroup) {
  switch ((itemGroup ?? '').trim().toUpperCase()) {
    case kGroupPctr:
      return ProductCategory.pctr;
    case kGroupCtr:
      return ProductCategory.ctr;
    case kGroupBondingGum:
      return ProductCategory.bondingGum;
    case kGroupVulcanizing:
      return ProductCategory.vulcanizingSolution;
    default:
      return ProductCategory.other;
  }
}

extension ProductCategoryLabel on ProductCategory {
  String get label => switch (this) {
        ProductCategory.pctr => 'Precured Tread Rubber',
        ProductCategory.ctr => 'Conventional Tread Rubber',
        ProductCategory.bondingGum => 'Bonding Gum',
        ProductCategory.vulcanizingSolution => 'Vulcanizing Solution',
        ProductCategory.other => 'Other',
      };

  String get shortLabel => switch (this) {
        ProductCategory.pctr => 'PCTR',
        ProductCategory.ctr => 'CTR',
        ProductCategory.bondingGum => 'Bonding Gum',
        ProductCategory.vulcanizingSolution => 'Vulcanizing Solution',
        ProductCategory.other => 'Other',
      };

  /// What the rep types a rate against. Tread rubber and bonding gum are
  /// negotiated per kilogram; solution is priced by the tin, because a 10L and
  /// a 30L can are separate Items with separate rates.
  String get rateUnit =>
      this == ProductCategory.vulcanizingSolution ? 'can' : 'kg';

  /// What the pool of minimum stock is counted in — the Item's stock UOM.
  String get stockUnit => switch (this) {
        ProductCategory.pctr => 'rolls',
        ProductCategory.ctr => 'rolls',
        ProductCategory.bondingGum => 'kg',
        ProductCategory.vulcanizingSolution => 'cans',
        ProductCategory.other => 'units',
      };

  /// True when the family is sold by weight, so a derived kilogram figure means
  /// something and belongs on the proforma.
  bool get isSoldByWeight => this != ProductCategory.vulcanizingSolution;
}

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

int _int(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

/// An Item as the order screen needs it: the raw Frappe document plus the
/// handful of custom fields that describe how it is packed.
class Product {
  final Map<String, dynamic> doc;
  final ProductCategory category;

  Product(this.doc) : category = categoryOfGroup(doc['item_group'] as String?);

  String get code => '${doc['name']}';
  String get name => '${doc['item_name'] ?? doc['name']}';
  String get uom => '${doc['stock_uom'] ?? ''}';

  /// What one **belt** weighs.
  ///
  /// The field is named `custom_avg_weight_per_roll`, which is a
  /// misnomer inherited from the item master — it holds the per-belt weight,
  /// not the per-roll one. The live data settles it: 174 MLG 120 reads 10.1
  /// with 4 belts and a roll weight of 40.4, and 102 AJAX 60 reads 2.4 with 14
  /// belts and 33.6. In both cases `field x belts = roll weight`, so the field
  /// is per belt.
  ///
  /// Renaming it in ERPNext would break every existing import sheet, so the
  /// name stays wrong on the backend and is corrected here, once.
  double get weightPerBelt {
    final stored = _num(doc['custom_avg_weight_per_roll']);
    if (stored > 0) return stored;
    // Derived when only the roll weight was filled in, so a half-complete item
    // still prices belts rather than refusing them.
    return beltsPerRoll > 0 ? weightPerRoll / beltsPerRoll : 0;
  }

  /// How many belts come off one roll. PCTR only.
  int get beltsPerRoll => _int(doc['custom_belts_per_roll']);

  /// What one **roll** weighs. Used by PCTR and CTR alike — the field means the
  /// same thing for both, and it is the number a roll is priced by.
  double get weightPerRoll {
    final stored = _num(doc['custom_weight_per_roll']);
    if (stored > 0) return stored;
    // Derived when only the belt weight was filled in. Belts x belt weight is
    // exactly how the roll figure is arrived at in the master anyway.
    final perBelt = _num(doc['custom_avg_weight_per_roll']);
    return (perBelt > 0 && beltsPerRoll > 0) ? perBelt * beltsPerRoll : 0;
  }

  /// Vulcanizing solution only: tin size in litres, 10 or 30.
  double get packLitres => _num(doc['custom_pack_litres']);

  /// What one roll of this product weighs, for pricing. Both tread rubber
  /// families now read the same field.
  double get rollWeight => switch (category) {
        ProductCategory.pctr || ProductCategory.ctr => weightPerRoll,
        _ => 0,
      };

  /// True when the Item is missing the custom fields its category needs. The
  /// row shows this instead of pretending the maths worked, so a bad product
  /// import surfaces at the point of sale rather than on the proforma.
  ///
  /// PCTR needs a belt count as well as a weight, because it is sold in belts
  /// and the pool cuts rolls into them. Either weight field satisfies the
  /// weight requirement — each derives the other given the belt count.
  bool get isMisconfigured => switch (category) {
        ProductCategory.pctr => weightPerRoll <= 0 || beltsPerRoll <= 0,
        ProductCategory.ctr => weightPerRoll <= 0,
        ProductCategory.vulcanizingSolution => packLitres <= 0,
        _ => false,
      };
}

/// One line a rep is building. Holds what was typed — rolls, belts, boxes,
/// cans, and a rate per kg — and derives everything ERPNext needs.
class OrderLine {
  final Product product;

  /// Whole rolls. Used by PCTR, CTR, and (as loose rolls) bonding gum.
  int rolls;

  /// PCTR only. CTR is always sold as whole fixed-weight rolls.
  int looseBelts;

  /// Bonding gum only. One box is [kBgRollsPerBox] rolls.
  int boxes;

  /// Vulcanizing solution only.
  int cans;

  /// Exactly what the rep typed: per kg for everything sold by weight, per tin
  /// for solution. Never taken from `standard_rate`.
  double rate;

  /// Pins the line to one dated batch.
  ///
  /// Nothing in the app sets this any more. The oldest stock of a product goes
  /// out first regardless, and with the shelf life these products have there is
  /// no reason for a rep to pick a batch or for a customer to agree to one. The
  /// field and the drawdown that honours it are kept because the reservation
  /// model genuinely supports pinning a batch, should a reason ever appear.
  String? agedBatch;

  OrderLine({
    required this.product,
    this.rolls = 0,
    this.looseBelts = 0,
    this.boxes = 0,
    this.cans = 0,
    this.rate = 0,
    this.agedBatch,
  });

  /// The quantity ERPNext stores, in the Item's stock UOM. Rolls for tread
  /// rubber — fractional when loose belts are involved, because a belt is a
  /// known fraction of a roll — kilograms for bonding gum, tins for solution.
  double get qty {
    switch (product.category) {
      case ProductCategory.pctr:
        final beltFraction = product.beltsPerRoll > 0
            ? looseBelts / product.beltsPerRoll
            : 0.0;
        return rolls + beltFraction;
      case ProductCategory.ctr:
        return rolls.toDouble();
      case ProductCategory.bondingGum:
        return (boxes * kBgRollsPerBox + rolls) * kBgKgPerRoll;
      case ProductCategory.vulcanizingSolution:
        return cans.toDouble();
      case ProductCategory.other:
        return rolls.toDouble();
    }
  }

  /// The weight the customer is actually billed for. Zero for solution, which
  /// is sold by the tin.
  double get totalWeightKg {
    switch (product.category) {
      case ProductCategory.pctr:
        return rolls * product.weightPerRoll +
            looseBelts * product.weightPerBelt;
      case ProductCategory.ctr:
        return rolls * product.weightPerRoll;
      case ProductCategory.bondingGum:
        return qty;
      default:
        return 0;
    }
  }

  /// The rate ERPNext stores, quoted against [qty] rather than against weight.
  /// For tread rubber that is a per-roll figure derived from the roll weight;
  /// for everything else the rep's rate already matches the quantity unit.
  double get lineRate {
    switch (product.category) {
      case ProductCategory.pctr:
      case ProductCategory.ctr:
        return rate * product.rollWeight;
      default:
        return rate;
    }
  }

  /// What the customer pays for this line. Equal to weight x rate per kg for
  /// anything sold by weight, which is the number the rep quoted out loud.
  double get amount => qty * lineRate;

  bool get isEmpty => qty <= 0;

  /// True once the line has a quantity but no price. Reps price every line by
  /// hand, so an unpriced line is an unfinished line, not a free one.
  bool get needsRate => !isEmpty && rate <= 0;

  /// Whole rolls, kilograms or tins to book against the shared pool. Minimum
  /// stock is counted in whole units, so the fractional roll that belts create
  /// is deliberately not part of this — belts are booked separately.
  double get reserveQty {
    switch (product.category) {
      case ProductCategory.pctr:
      case ProductCategory.ctr:
        return rolls.toDouble();
      default:
        return qty;
    }
  }

  /// Loose belts to book against the pool. PCTR only.
  int get reserveBelts =>
      product.category == ProductCategory.pctr ? looseBelts : 0;

  /// Human-readable summary of what was entered, for the review line and the
  /// proforma's description column. The derived weight is spelled out because
  /// that, not the roll count, is what the customer is billed on.
  String get packingNote {
    switch (product.category) {
      case ProductCategory.pctr:
        final parts = <String>[
          if (rolls > 0) '$rolls roll${rolls == 1 ? '' : 's'}',
          if (looseBelts > 0)
            '$looseBelts loose belt${looseBelts == 1 ? '' : 's'}',
        ];
        return '${parts.join(' + ')} · ${totalWeightKg.toStringAsFixed(2)} kg (avg)';
      case ProductCategory.ctr:
        return '$rolls roll${rolls == 1 ? '' : 's'} · '
            '${totalWeightKg.toStringAsFixed(2)} kg';
      case ProductCategory.bondingGum:
        final parts = <String>[
          if (boxes > 0) '$boxes box${boxes == 1 ? '' : 'es'}',
          if (rolls > 0) '$rolls roll${rolls == 1 ? '' : 's'}',
        ];
        return '${parts.join(' + ')} · ${qty.toStringAsFixed(0)} kg';
      case ProductCategory.vulcanizingSolution:
        final litres = product.packLitres.toStringAsFixed(0);
        return '$cans x ${litres}L can${cans == 1 ? '' : 's'}';
      case ProductCategory.other:
        return '$rolls ${product.uom}';
    }
  }

  /// The Sales Order Item payload. `qty` and `rate` are what ERPNext prices
  /// off; the custom fields preserve what the rep actually counted and quoted,
  /// which is what the warehouse picks against and what the proforma prints.
  Map<String, dynamic> toSalesOrderItem() => {
        'item_code': product.code,
        'qty': double.parse(qty.toStringAsFixed(4)),
        'rate': double.parse(lineRate.toStringAsFixed(4)),
        // Sent explicitly rather than left to the server. ERPNext derives
        // `amount` for a Sales Order Item, but `Lead Order Item` is our own
        // child table and nothing calculates it — so a lead order's lines
        // arrived worth zero, and the manager reviewing it saw a nil order
        // against rates the rep had entered correctly.
        'amount': double.parse(amount.toStringAsFixed(2)),
        'custom_product_category': product.category.shortLabel,
        'custom_rolls': rolls,
        'custom_loose_belts': looseBelts,
        'custom_boxes': boxes,
        'custom_cans': cans,
        'custom_rate_per_kg': rate,
        'custom_total_weight': double.parse(totalWeightKg.toStringAsFixed(3)),
        'custom_packing_note': packingNote,
        if (agedBatch != null) 'custom_aged_batch': agedBatch,
      };
}
