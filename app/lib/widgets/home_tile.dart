// One tile of the home screen's grid: an icon and a label, tapped to open a
// screen.
//
// A label too long for one line on a 360-dp phone ("Payment Commitments")
// wrapped flush left against the tile's border while every other label sat
// centred, and the icon looked off-centre above it (18 Nov 2026, 1.1.18). The
// label is centred, padded inside the card and held to two lines.

import 'package:flutter/material.dart';

class HomeTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const HomeTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 40, color: const Color(0xFFF46A21)),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, height: 1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
