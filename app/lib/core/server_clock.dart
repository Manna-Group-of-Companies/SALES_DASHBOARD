import 'dart:io' show HttpDate;

/// The clock the app judges time-of-day rules against.
///
/// A rep controls the phone's clock, so `DateTime.now()` cannot decide whether
/// a punch falls inside its allowed window. Every Frappe response carries a
/// `Date` header, so the app learns the server's skew for free and corrects for
/// it. The server re-checks every punch anyway — this only stops the app from
/// offering a punch the server is going to refuse.
class ServerClock {
  static final ServerClock I = ServerClock._();
  ServerClock._();

  Duration _skew = Duration.zero;

  /// Feeds in the `Date` header of any response. Cheap, so the session
  /// interceptor calls it on every single one.
  void syncFromHeader(String? httpDate) {
    if (httpDate == null || httpDate.isEmpty) return;
    try {
      _skew = HttpDate.parse(httpDate).difference(DateTime.now().toUtc());
    } catch (_) {
      // Unparseable header — keep whatever skew we already had.
    }
  }

  /// Now, as the server sees it, rendered in the phone's own timezone. Before
  /// the first response lands this is just the device clock.
  DateTime now() => DateTime.now().add(_skew);
}
