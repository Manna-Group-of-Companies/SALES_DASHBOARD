


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
  Approval(this.title, this.name, this.rep, this.party, this.amount, this.kind,
      {this.lat,
        this.lng,
        this.image,
        this.custOutstanding = 0,
        this.custLimit = 0,
        this.orderTotal = 0,
        this.escalate = false});
}

