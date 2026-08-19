// The process cycle each product family goes through on the floor.
//
// PLACEHOLDER. The real stage lists are coming in a separate document, and
// none of the sequences below are from the factory — they are structurally
// plausible guesses that exist so the production screens can be built, tested
// and looked at now rather than after the document lands.
//
// When the real ones arrive, this file is the only thing that changes. The
// stage a line is on is stored as free text in `custom_production_stage`, so
// renaming or resequencing stages does not require a schema change; an order
// already sitting on a stage that no longer exists simply shows as off-sequence
// rather than breaking.

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/models/product_category.dart';

/// What a line is on before the floor has touched it.
const String kStageNotStarted = 'Not Started';

/// The terminal stage every family ends on. Kept common so "is this line
/// finished" is one comparison rather than four.
const String kStageDispatched = 'Dispatched';

const List<String> _pctrStages = [
  kStageNotStarted,
  'Compound Mixing',
  'Extrusion',
  'Curing',
  'Trimming',
  'Quality Check',
  'Packed',
  kStageDispatched,
];

const List<String> _ctrStages = [
  kStageNotStarted,
  'Compound Mixing',
  'Calendering',
  'Cutting to Length',
  'Quality Check',
  'Packed',
  kStageDispatched,
];

const List<String> _bondingGumStages = [
  kStageNotStarted,
  'Compound Mixing',
  'Sheeting',
  'Rolling',
  'Packed',
  kStageDispatched,
];

const List<String> _solutionStages = [
  kStageNotStarted,
  'Blending',
  'Filling',
  'Sealing',
  'Packed',
  kStageDispatched,
];

const List<String> _genericStages = [
  kStageNotStarted,
  'In Production',
  'Packed',
  kStageDispatched,
];

/// A line served out of minimum stock, whatever it is made of.
///
/// The goods already exist on a shelf — that is the whole point of the
/// minimum-stock pool — so none of the making stages apply. Showing a stock
/// line as "stage 3 of 8, Curing" describes work nobody is doing, and worse,
/// leaves the floor looking permanently behind on orders that were finished
/// before they were placed. All that is left is picking it and sending it.
const List<String> _fromStockStages = [
  kStageNotStarted,
  'Packed',
  kStageDispatched,
];

/// The stages a line of this family moves through, in order.
List<String> stagesFor(ProductCategory category) {
  switch (category) {
    case ProductCategory.pctr:
      return _pctrStages;
    case ProductCategory.ctr:
      return _ctrStages;
    case ProductCategory.bondingGum:
      return _bondingGumStages;
    case ProductCategory.vulcanizingSolution:
      return _solutionStages;
    case ProductCategory.other:
      return _genericStages;
  }
}

/// Same, but keyed by the category name stored on the order line, so the
/// production screens do not need the Item record to know the sequence.
///
/// [fromMinimumStock] overrides the family entirely: where the goods come from
/// decides whether they are made at all, and that outranks what they are made
/// of.
List<String> stagesForLabel(dynamic shortLabel,
    {bool fromMinimumStock = false}) {
  if (fromMinimumStock) return _fromStockStages;
  final s = '${shortLabel ?? ''}'.trim().toUpperCase();
  switch (s) {
    case 'PCTR':
      return _pctrStages;
    case 'CTR':
      return _ctrStages;
    case 'BONDING GUM':
      return _bondingGumStages;
    case 'VULCANIZING SOLUTION':
      return _solutionStages;
    default:
      return _genericStages;
  }
}

/// True when this order line is being served off the shelf rather than made.
bool isFromMinimumStock(Map<String, dynamic> item) =>
    '${item['custom_fulfilment_mode'] ?? ''}' == kFulfilMinimumStock;

/// The short cycle for goods already on a shelf, whatever they are made of.
///
/// Exposed so the production screen can draw the stock half of a split line
/// against it while the made half runs the full family cycle.
List<String> get fromStockStages => _fromStockStages;

/// The sequence for one order line, read straight off the line.
///
/// The single entry point the screens and the roll-up both use, so a stock line
/// cannot be counted against the full making cycle in one place and the short
/// one in another — which would have the order status disagreeing with the
/// screen the floor is looking at.
List<String> stagesForItem(Map<String, dynamic> item) => stagesForLabel(
      item['custom_product_category'],
      fromMinimumStock: isFromMinimumStock(item),
    );

/// Where a line has got to, 0 when untouched. -1 when the stored stage is not
/// in the sequence at all — which happens when the stage list is revised under
/// an order that is already running.
int stageIndex(List<String> stages, dynamic current) {
  final c = '${current ?? ''}'.trim();
  if (c.isEmpty || c == 'null') return 0;
  return stages.indexOf(c);
}

/// How far through the cycle, 0..1, for a progress bar.
double stageProgress(List<String> stages, dynamic current) {
  final i = stageIndex(stages, current);
  if (i <= 0 || stages.length < 2) return 0;
  return i / (stages.length - 1);
}

bool isDispatched(dynamic current) => '${current ?? ''}' == kStageDispatched;

// ---------------------------------------- what the floor is shown ---
//
// Paired with `client/src/domain/production.ts`. Both read
// `shared/fixtures/production_progress.json` in their tests.
//
// Dispatch Planning took `Dispatched` off the stage picker: the floor cannot
// reach that stage any more, it is written only once a line's full ordered
// quantity has actually gone out. Measuring the floor's own progress against
// it left a packed — i.e. finished — line reading "Stage 2 of 3" behind a
// half-empty bar, which says "you are behind" about work that is done.
//
// So the floor is shown its own stages: the sequence up to and including
// `Packed`. `Dispatched` stays in the stored sequence and the order-level
// roll-up still ranks it above `Packed` to decide Ready vs Dispatched — that
// is deliberately untouched. This changes only what is displayed.

/// The stages the floor actually works — the sequence without `Dispatched`.
List<String> workSequence(List<String> stages) =>
    stages.where((s) => s != kStageDispatched).toList();

/// Where a stage sits among the floor's own stages, 1-based, or -1 when it is
/// off-sequence.
///
/// `Dispatched` maps onto the last worked stage rather than past the end: the
/// goods are gone, so the floor's part is finished, and reporting it as a step
/// beyond the list would read as work somebody skipped.
int workPosition(List<String> stages, dynamic current) {
  final work = workSequence(stages);
  final c = '${current ?? ''}'.trim();
  final stage = (c.isEmpty || c == 'null') ? kStageNotStarted : c;
  if (stage == kStageDispatched) return work.length;
  final i = work.indexOf(stage);
  return i < 0 ? -1 : i + 1;
}

/// How many stages the floor works. The denominator in "step 7 of 7".
int workTotal(List<String> stages) => workSequence(stages).length;

/// 0..1 across the floor's own stages. Off-sequence shows none, never full.
double workProgress(List<String> stages, dynamic current) {
  final total = workTotal(stages);
  final pos = workPosition(stages, current);
  if (pos < 0 || total <= 1) return 0;
  return (pos - 1) / (total - 1);
}

/// True once the floor has nothing left to do on this line.
bool workComplete(List<String> stages, dynamic current) {
  final pos = workPosition(stages, current);
  return pos > 0 && pos == workTotal(stages);
}
