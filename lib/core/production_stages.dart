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
List<String> stagesForLabel(dynamic shortLabel) {
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
