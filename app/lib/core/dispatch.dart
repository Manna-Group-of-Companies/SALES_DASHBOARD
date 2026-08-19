// How much of an order line remains to be dispatched.
//
// Paired with `client/src/domain/dispatch.ts`. Both read
// `shared/fixtures/dispatch.json` in their tests. See `shared/README.md`.
//
// `custom_dispatched_rolls`/`custom_dispatched_loose_belts` are cumulative
// across every `Manna Dispatch` that has ever touched this line — never one
// dispatch's own amount. A line only reaches fully-dispatched once the
// running total catches up with what was ordered, however many rounds that
// takes.

/// Frappe returns an unset Int as null, '' or the string 'null'.
num _num(dynamic v) {
  if (v == null) return 0;
  final s = v is String ? v.trim() : v;
  if (s == '' || s == 'null' || s == 'undefined') return 0;
  if (s is num) return s;
  return num.tryParse('$s') ?? 0;
}

/// What is left of this line for a dispatch to carry.
///
/// Clamped at zero, never negative — an over-dispatched line (a data
/// mistake: cumulative recorded greater than ordered) reads as nothing
/// remaining rather than a negative number a picker would have to guard
/// against separately. This is the opposite rounding direction from
/// `production_stages.dart`'s "errors round down": under-reporting what has
/// already left the building is the more dangerous failure here, so this
/// rounds the other way on purpose.
({int rolls, int looseBelts}) remainingToDispatch(Map<String, dynamic> line) {
  final rolls =
      _num(line['custom_rolls']).toInt() - _num(line['custom_dispatched_rolls']).toInt();
  final looseBelts = _num(line['custom_loose_belts']).toInt() -
      _num(line['custom_dispatched_loose_belts']).toInt();
  return (rolls: rolls < 0 ? 0 : rolls, looseBelts: looseBelts < 0 ? 0 : looseBelts);
}

/// True once both counters have nothing left — rolls and belts do not
/// average out.
bool isFullyDispatched(Map<String, dynamic> line) {
  final left = remainingToDispatch(line);
  return left.rolls <= 0 && left.looseBelts <= 0;
}
