// The dead end a build too old to be trusted arrives at.
//
// Deliberately offers no way past it. Everything this app enforces — the stock
// headroom check, the 1 pm edit cutoff, the rate lock — runs on the phone, so a
// build that predates a rule does not know to apply it and the backend will not
// catch what it lets through. Letting a rep "continue anyway" would put exactly
// that build back in front of live stock.
//
// It does offer a retry, because the other way to land here is the office
// having just raised the minimum while a rep was mid-round.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_version.dart';

class UpdateRequiredScreen extends StatelessWidget {
  final VersionGate gate;

  /// Re-runs the check. The office may have corrected the setting.
  final Future<void> Function()? onRetry;

  const UpdateRequiredScreen({super.key, required this.gate, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.system_update,
                    size: 64, color: Color(0xFFF46A21)),
                const SizedBox(height: 24),
                const Text(
                  'Update needed',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 14),
                Text(
                  gate.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, height: 1.45),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7F8),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFECECEC)),
                  ),
                  child: Column(
                    children: [
                      _row('Installed', kAppVersion),
                      if (gate.required != null) ...[
                        const SizedBox(height: 8),
                        _row('Needed', gate.required!),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Nothing you have already sent is lost. Ask the office for '
                  'the new app file, install it, and sign in again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 22),
                  OutlinedButton(
                    onPressed: onRetry,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('Check again'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 13, color: Colors.black54)),
          Text(value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      );
}
