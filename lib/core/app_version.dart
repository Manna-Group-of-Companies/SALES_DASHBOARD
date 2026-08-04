// Which builds are still allowed to write.
//
// WHY THIS EXISTS
//
// Every rule the app enforces — the 1 pm edit cutoff, the booking headroom
// check, the rate lock — lives in the app, because the plan no longer runs
// Server Scripts. That is survivable while everyone is on the same build. It
// stops being survivable the moment they are not: a rep still carrying an APK
// from before minimum stock existed does not know the reservation counters are
// there, and its orders walk straight past them. Nothing on the server notices,
// and the damage shows up as a warehouse that is short.
//
// So the backend gets to name the oldest build it will accept, and anything
// older refuses to work until it is updated.
//
// WHAT THIS CANNOT DO
//
// It only binds builds that contain this check. The APKs already in the field
// have no idea it exists and will keep writing regardless — this protects the
// fleet from *this version onward*, which is the earliest it could possibly
// have started. Getting everyone onto a build that has the gate is a one-time
// manual push, and until that is done the guarantee is not there.
//
// It also fails open. A rep standing in a shop with a backend that will not
// answer needs to keep working, and a settings row that failed to load is a
// far more likely explanation than a fleet-wide emergency. The gate closes on
// a definite answer, never on silence.

/// This build, as `major.minor.patch`. Must track the `version:` line in
/// pubspec.yaml — they are compared against the same backend field.
const String kAppVersion = '1.1.0';

/// What the backend decided about this build.
enum VersionVerdict {
  /// Recent enough to use.
  ok,

  /// Too old to be trusted with writes. Must update before continuing.
  blocked,

  /// The backend did not answer. Treated as [ok] — see the note above.
  unknown,
}

class VersionGate {
  final VersionVerdict verdict;

  /// The oldest build the backend accepts, when it said so.
  final String? required;

  /// What the office wants shown on the block screen, when they set it.
  final String? message;

  const VersionGate(this.verdict, {this.required, this.message});

  bool get blocked => verdict == VersionVerdict.blocked;

  /// What to put on the block screen.
  String get text {
    final m = (message ?? '').trim();
    if (m.isNotEmpty) return m;
    return 'This version of the app is too old to take orders safely. '
        'Update to $required or newer and sign in again.';
  }
}

/// Compares two `major.minor.patch` strings.
///
/// Returns <0 when [a] is older, 0 when they match, >0 when [a] is newer.
/// Missing parts count as zero, so `1.2` and `1.2.0` are the same build. Junk
/// on either side compares equal rather than guessing, because a wrong guess
/// here either locks out a working rep or lets a bad build through.
int compareVersions(String a, String b) {
  final left = _parse(a);
  final right = _parse(b);
  if (left == null || right == null) return 0;

  for (var i = 0; i < 3; i++) {
    final d = left[i] - right[i];
    if (d != 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

List<int>? _parse(String raw) {
  // Tolerates a build suffix (1.2.0+7) and stray whitespace, since the value
  // is typed into a Frappe field by hand.
  var s = raw.trim();
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  if (s.isEmpty) return null;

  final parts = s.split('.');
  final out = <int>[0, 0, 0];
  for (var i = 0; i < 3 && i < parts.length; i++) {
    final n = int.tryParse(parts[i].trim());
    if (n == null) return null;
    out[i] = n;
  }
  return out;
}

/// Whether [current] satisfies a required minimum.
///
/// A blank or unparseable minimum is "no minimum set" rather than "block
/// everyone", so clearing the field in Desk turns the gate off instead of
/// locking the whole field team out.
VersionGate checkVersion(String current, dynamic minimumRaw,
    {dynamic messageRaw}) {
  final min = '${minimumRaw ?? ''}'.trim();
  if (min.isEmpty || min == 'null') {
    return const VersionGate(VersionVerdict.ok);
  }
  if (_parse(min) == null) return const VersionGate(VersionVerdict.ok);

  final msg = '${messageRaw ?? ''}'.trim();
  if (compareVersions(current, min) < 0) {
    return VersionGate(VersionVerdict.blocked,
        required: min, message: msg.isEmpty || msg == 'null' ? null : msg);
  }
  return VersionGate(VersionVerdict.ok, required: min);
}
