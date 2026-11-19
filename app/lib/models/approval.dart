


class Approval {
  final String title;
  final String name;
  final dynamic rep;
  final dynamic party;
  final dynamic amount;
  final String kind;
  final dynamic lat;
  final dynamic lng;
  final String? image;
  double custOutstanding;
  double custLimit;
  double orderTotal;
  bool escalate;

  /// The rep's commitment on an over-limit order, and when they said it would
  /// be met — see `core/credit_commitment.dart`. Null on anything else.
  dynamic commitment;
  dynamic commitmentDue;

  /// The customer's display name, and the day the order was raised — the GM
  /// queue reads both; blank where a caller did not ask for them.
  String partyName;
  String placedOn;

  /// "Rs 25,000 overdue past their Net-30 terms (oldest 12 days late)" when the
  /// customer is overdue past their payment terms — the second reason an order
  /// reaches the GM (11 Oct 2026). Blank otherwise.
  String pastTerms = '';
  Approval(this.title, this.name, this.rep, this.party, this.amount, this.kind,
      {this.lat,
        this.lng,
        this.image,
        this.custOutstanding = 0,
        this.custLimit = 0,
        this.orderTotal = 0,
        this.escalate = false,
        this.commitment,
        this.commitmentDue,
        this.partyName = '',
        this.placedOn = ''});
}

