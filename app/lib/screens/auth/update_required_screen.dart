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
//
// Since 21 August 2026 it also offers the update itself. This screen used to
// end at "ask the office for the new app file", which meant an APK on WhatsApp
// and somebody remembering to send it — the step that most often did not
// happen, leaving a rep stuck here with nothing they could do about it.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_update.dart';
import 'package:manna_field_sales/core/app_version.dart';
import 'package:manna_field_sales/screens/home/update_sheet.dart';
import 'package:manna_field_sales/services/update_service.dart';

class UpdateRequiredScreen extends StatefulWidget {
  final VersionGate gate;

  /// Re-runs the check. The office may have corrected the setting.
  final Future<void> Function()? onRetry;

  const UpdateRequiredScreen({super.key, required this.gate, this.onRetry});

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  AvailableUpdate? _update;
  bool _looking = true;

  VersionGate get gate => widget.gate;
  Future<void> Function()? get onRetry => widget.onRetry;

  @override
  void initState() {
    super.initState();
    _look();
  }

  /// Is there actually a build to install? Asked on arrival, because the whole
  /// point of this screen is that the rep cannot go anywhere until there is.
  Future<void> _look() async {
    final u = await UpdateService.check();
    if (!mounted) return;
    setState(() {
      _update = u;
      _looking = false;
    });
  }

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
                if (_looking)
                  const Text(
                    'Looking for the new version…',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  )
                else if (_update != null) ...[
                  const Text(
                    'Nothing you have already sent is lost. Install the new '
                    'version and sign in again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () =>
                        showUpdateSheet(context, _update!, mandatory: true),
                    icon: const Icon(Icons.download),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('Update to ${_update!.label}'),
                    ),
                  ),
                ] else
                  // No published build to offer: either the phone is offline or
                  // nothing newer has been released yet. Falling back to the
                  // old instruction is right here — it is still true, and a
                  // dead end with no instruction at all is worse.
                  const Text(
                    'Nothing you have already sent is lost. Connect to the '
                    'internet and try again, or ask the office for the new '
                    'app file.',
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
