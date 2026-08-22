// The "Update available" prompt, and the download that follows it.
//
// One sheet, used from two places that want the same thing for different
// reasons: the home screen offers it when a newer build exists, and
// `UpdateRequiredScreen` offers it when the build in hand is too old to be
// allowed to work at all. Before 21 August 2026 both said some version of "ask
// the office for the new app file" — which meant WhatsApp, and meant somebody
// remembering.
//
// Dismissible on the home screen, because a rep in front of a customer should
// not be made to install anything mid-order. The gate is what actually forces
// an old build to update; this only ever makes it easy.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/app_update.dart';
import 'package:manna_field_sales/services/update_service.dart';

Future<void> showUpdateSheet(
  BuildContext context,
  AvailableUpdate update, {
  /// True on the block screen: the rep has nothing else they can do, so the
  /// sheet does not offer "Later".
  bool mandatory = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: !mandatory,
    enableDrag: !mandatory,
    isScrollControlled: true,
    builder: (_) => _UpdateSheet(update: update, mandatory: mandatory),
  );
}

class _UpdateSheet extends StatefulWidget {
  final AvailableUpdate update;
  final bool mandatory;
  const _UpdateSheet({required this.update, required this.mandatory});

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  double? _progress;
  String? _error;
  bool _installing = false;
  CancelToken? _cancel;

  bool get _busy => _progress != null || _installing;

  @override
  void dispose() {
    // A rep who backgrounds the app mid-download should not leave a request
    // running against a screen that is gone.
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _error = null;
      _progress = 0;
      _cancel = CancelToken();
    });
    try {
      final file = await UpdateService.download(
        widget.update,
        cancelToken: _cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _progress = null;
        _installing = true;
      });

      final problem = await UpdateService.install(file);
      if (!mounted) return;
      if (problem != null) {
        setState(() {
          _installing = false;
          _error = problem;
        });
        return;
      }
      // The installer is now in front of the rep. Nothing else to do here —
      // and if they go through with it this process is replaced mid-sentence.
      Navigator.of(context).maybePop();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _installing = false;
        _error = e.type == DioExceptionType.cancel
            ? null
            : 'The download did not finish. Check the connection and try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _installing = false;
        _error = 'The download did not finish. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.system_update, size: 44, color: Color(0xFFF46A21)),
            const SizedBox(height: 14),
            Text(
              widget.mandatory ? 'Update required' : 'Update available',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Version ${u.label}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            if (u.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F7F8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(u.notes,
                    style: const TextStyle(fontSize: 13, height: 1.4)),
              ),
            ],
            const SizedBox(height: 18),

            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text('Downloading… ${((_progress ?? 0) * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ] else if (_installing) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Opening the installer…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.red)),
            ],

            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _run,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(_error != null ? 'Try again' : 'Update now'),
              ),
            ),
            if (!widget.mandatory) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
                child: const Text('Later'),
              ),
            ],
            const SizedBox(height: 4),
            const Text(
              'Android will ask once for permission to install app files. '
              'Nothing you have already sent is affected.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}
