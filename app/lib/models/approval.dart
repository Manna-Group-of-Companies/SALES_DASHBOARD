


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
  Approval(this.title, this.name, this.rep, this.party, this.amount, this.kind,
      {this.lat,
        this.lng,
        this.image,
        this.custOutstanding = 0,
        this.custLimit = 0,
        this.orderTotal = 0,
        this.escalate = false,
        this.commitment,
        this.commitmentDue});
}

