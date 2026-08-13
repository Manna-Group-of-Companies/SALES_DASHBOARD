import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';


Future<void> shareOnWhatsApp(BuildContext context, String text) async {
  final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Could not open WhatsApp')));
  }
}

