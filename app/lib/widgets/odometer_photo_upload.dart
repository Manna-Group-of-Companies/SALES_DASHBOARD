// An odometer photo, and whether it actually reached the server.
//
// The leg dialogs used to tick the button — "Start photo ✓" — the moment the
// camera returned, before a single byte had left the phone. The upload ran only
// after the rep tapped Start, inside a `catch (_) {}`, and a failure there saved
// the leg with no photo and said nothing. So the tick meant "photographed", the
// rep read it as "done", and HR found legs with no evidence behind the claim.
//
// Here the upload starts as soon as the photo is taken, while the rep is still
// in the dialog and can do something about it. The green tick appears only when
// the server has answered with a file url. Anything short of that is said out
// loud, with Retry — which re-sends the same photo, because the odometer may no
// longer read what it read when the shot was taken.

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/widgets/photo_source_sheet.dart';

enum OdometerPhotoStatus { none, uploading, uploaded, failed }

/// Sends a photo, answering with its file url, or null if none came back.
typedef OdometerPhotoUploader = Future<String?> Function(String path);

/// Gets a photo from the rep, answering with its path, or null if they backed
/// out.
typedef OdometerPhotoPicker = Future<String?> Function(BuildContext context);

class OdometerPhotoUpload extends StatefulWidget {
  /// What the photo is of — "Start odometer photo".
  final String label;

  /// Short name used in the result lines — "Start photo".
  final String shortLabel;

  final OdometerPhotoUploader upload;

  /// Defaults to the camera, or camera-or-gallery when [allowGallery] is set.
  final OdometerPhotoPicker? pick;

  /// Editing a leg after the fact: the shot is often already in the phone's
  /// roll, and the vehicle may be gone.
  final bool allowGallery;

  /// A photo is already on the leg. Changes the prompt to "Replace", so a rep
  /// correcting a reading does not think the evidence is missing.
  final bool hasExisting;

  /// Called with the url once uploaded, and with null whenever there is no
  /// usable upload — including the moment a retake starts.
  final ValueChanged<String?> onUrl;

  /// Called whenever the state changes, so the dialog can hold its Save button
  /// while a photo is still on its way.
  final ValueChanged<OdometerPhotoStatus>? onStatus;

  const OdometerPhotoUpload({
    super.key,
    required this.label,
    required this.shortLabel,
    required this.upload,
    required this.onUrl,
    this.onStatus,
    this.pick,
    this.allowGallery = false,
    this.hasExisting = false,
  });

  @override
  State<OdometerPhotoUpload> createState() => _OdometerPhotoUploadState();
}

class _OdometerPhotoUploadState extends State<OdometerPhotoUpload> {
  static const _green = Color(0xFF1B7F3B);
  static const _greenBg = Color(0xFFE7F6EC);
  static const _red = Color(0xFFB91C1C);
  static const _redBg = Color(0xFFFDECEC);

  OdometerPhotoStatus _status = OdometerPhotoStatus.none;
  String? _path;
  String? _error;

  /// Bumped per attempt; a result from an older attempt is dropped. No control
  /// is offered while an upload is out, so the screen cannot start a second one
  /// today — this keeps a late answer from ever overwriting a newer photo if
  /// that changes.
  int _attempt = 0;

  void _set(OdometerPhotoStatus s, {String? error}) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _error = error;
    });
    widget.onStatus?.call(s);
  }

  Future<String?> _defaultPick(BuildContext context) async {
    if (widget.allowGallery) {
      return (await pickPhoto(context, title: widget.label))?.path;
    }
    return (await ImagePicker()
            .pickImage(source: ImageSource.camera, imageQuality: 60))
        ?.path;
  }

  Future<void> _take() async {
    final path = await (widget.pick ?? _defaultPick)(context);
    if (path == null || !mounted) return;
    _path = path;
    await _send();
  }

  Future<void> _send() async {
    final path = _path;
    if (path == null) return;
    final attempt = ++_attempt;
    // Whatever was uploaded before is no longer the photo on screen.
    widget.onUrl(null);
    _set(OdometerPhotoStatus.uploading);
    try {
      final url = await widget.upload(path);
      if (!mounted || attempt != _attempt) return;
      if (url == null || url.isEmpty) {
        // upload_file answered, but not with a file. Treated as the failure it
        // is: saving the leg on the strength of this would lose the photo the
        // same silent way as before.
        _set(OdometerPhotoStatus.failed,
            error: 'The server did not keep the photo.');
        return;
      }
      widget.onUrl(url);
      _set(OdometerPhotoStatus.uploaded);
    } catch (e) {
      if (!mounted || attempt != _attempt) return;
      _set(OdometerPhotoStatus.failed, error: humanError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case OdometerPhotoStatus.none:
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _take,
            icon: const Icon(Icons.camera_alt, size: 18),
            label: Text(widget.hasExisting
                ? 'Replace ${widget.shortLabel.toLowerCase()}'
                : widget.label),
          ),
        );

      case OdometerPhotoStatus.uploading:
        return _panel(
          colour: Colors.black54,
          background: const Color(0xFFF3F4F6),
          leading: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          title: 'Uploading ${widget.shortLabel.toLowerCase()}…',
        );

      case OdometerPhotoStatus.uploaded:
        return _panel(
          colour: _green,
          background: _greenBg,
          leading: const Icon(Icons.check_circle, color: _green, size: 22),
          title: '${widget.shortLabel} uploaded',
          action: TextButton(onPressed: _take, child: const Text('Retake')),
        );

      case OdometerPhotoStatus.failed:
        return _panel(
          colour: _red,
          background: _redBg,
          leading: const Icon(Icons.error, color: _red, size: 22),
          title: '${widget.shortLabel} did not upload',
          detail: '${_error ?? 'Something went wrong.'} '
              'Retry, or the leg saves without it.',
          action: TextButton(onPressed: _send, child: const Text('Retry')),
        );
    }
  }

  Widget _panel({
    required Color colour,
    required Color background,
    required Widget leading,
    required String title,
    String? detail,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        leading,
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14, color: colour)),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(detail,
                    style: TextStyle(fontSize: 12, color: colour)),
              ),
          ]),
        ),
        if (action != null) action,
      ]),
    );
  }
}
