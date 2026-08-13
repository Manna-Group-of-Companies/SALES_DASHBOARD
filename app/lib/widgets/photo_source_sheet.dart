import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Asks whether a photo comes from the camera or the gallery, then picks it.
///
/// Returns null if the rep backs out of either the sheet or the picker, so
/// callers can treat "no photo" and "cancelled" the same way.
Future<XFile?> pickPhoto(BuildContext context, {String title = 'Photo'}) async {
  final src = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (_) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: const Icon(Icons.camera_alt),
          title: const Text('Take photo'),
          onTap: () => Navigator.pop(context, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: const Text('Choose from gallery'),
          onTap: () => Navigator.pop(context, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (src == null) return null;
  return ImagePicker().pickImage(source: src, imageQuality: 60, maxWidth: 1280);
}
