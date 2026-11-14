// Mode of delivery: who pays the courier (14 Nov 2026, the user: "mode of
// delivery Paid / To Pay courier"). Paid - we pay the courier; To Pay - the
// customer pays it on delivery. Chosen on every order the phone takes and
// carried onto the Sales Order a lead order becomes.
//
// Held on Sales Order and Lead Order as `custom_delivery_mode`, a Select of
// exactly these values. Until that field exists on a site, Frappe drops the
// value on save without an error, so a build carrying this is safe to install
// first.

const String kFieldDeliveryMode = 'custom_delivery_mode';

const String kDeliveryPaid = 'Paid';
const String kDeliveryToPay = 'To Pay';
const List<String> kDeliveryModes = [kDeliveryPaid, kDeliveryToPay];

/// [v] as one of [kDeliveryModes], or null. Anything else - unset, 'null',
/// a value from a later option list - reads as not chosen, so the rep is
/// asked again rather than an order going out with a guess.
String? deliveryModeOf(Object? v) {
  final s = '${v ?? ''}'.trim();
  return kDeliveryModes.contains(s) ? s : null;
}

/// How the choice reads on screen.
String deliveryModeLabel(String mode) =>
    mode == kDeliveryToPay ? 'Courier - To Pay' : 'Courier - Paid';
