// Two choices on every order the phone takes (14 Nov 2026, the user), both
// carried onto the Sales Order a lead order becomes:
//
//   - Freight: Paid (we pay the carrier) or To Pay (the customer pays it on
//     delivery). Held in `custom_delivery_mode` - the name it shipped under
//     before the mode of delivery below was asked for; phones hold it, so it
//     stays.
//   - Mode of delivery: By Road, By KSRTC or By Railway. Held in
//     `custom_transport_mode`.
//
// Both are Selects of exactly these values on Sales Order and Lead Order.
// Until a field exists on a site, Frappe drops the value on save without an
// error, so a build carrying this is safe to install first.

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

/// How the freight choice reads on screen.
String deliveryModeLabel(String mode) => mode;

const String kFieldTransportMode = 'custom_transport_mode';

const String kByRoad = 'By Road';
const String kByKsrtc = 'By KSRTC';
const String kByRailway = 'By Railway';
const List<String> kTransportModes = [kByRoad, kByKsrtc, kByRailway];

/// [v] as one of [kTransportModes], or null - asked again rather than guessed.
String? transportModeOf(Object? v) {
  final s = '${v ?? ''}'.trim();
  return kTransportModes.contains(s) ? s : null;
}
