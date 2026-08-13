
import 'package:flutter/material.dart';


class InfoBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const InfoBox(
      {required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color))),
      ]),
    );
  }
}

