// ============================================================
// Manna Field Sales — v4
// Login -> Home dashboard (summary + tiles)
//   Customers -> [ Check-in | Order | Collection ]
//   My Visits / My Orders / My Collections (history)
// ============================================================

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:manna_field_sales/app.dart';
import 'package:manna_field_sales/core/server_clock.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Not awaited: sign-in takes far longer than reading one number, and the
  // first live response overrides it anyway.
  unawaited(ServerClock.I.restore());
  runApp(const MannaApp());
}
