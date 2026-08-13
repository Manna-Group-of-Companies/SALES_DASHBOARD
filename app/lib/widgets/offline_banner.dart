// The strip that admits a screen is showing yesterday's data.
//
// Every cached screen carries this. A rep reading a balance, a booked figure or
// a leave count off a phone has no other way to tell whether it came from the
// server a second ago or from the last time they had signal — and the answer
// changes what they should say to the customer in front of them.
//
// Renders nothing at all when the data is live, so it costs a screen nothing to
// include unconditionally.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/services/offline_cache.dart';

class OfflineBanner extends StatelessWidget {
  /// The staleness line, from [OfflineCache.ageLabel] or
  /// [OfflineCache.worstAge]. Empty means live, and renders nothing.
  final String label;

  const OfflineBanner(this.label, {super.key});

  /// For a screen built from one cached read.
  factory OfflineBanner.forKey(String key) =>
      OfflineBanner(OfflineCache.ageLabel(key));

  /// For a screen built from several, which is only as fresh as its stalest
  /// part.
  factory OfflineBanner.forKeys(List<String> keys) =>
      OfflineBanner(OfflineCache.worstAge(keys));

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF4E5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 15, color: Color(0xFFB35309)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFFB35309))),
          ),
        ],
      ),
    );
  }
}
