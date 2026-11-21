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
import 'package:manna_field_sales/services/sync_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Not awaited: sign-in takes far longer than reading one number, and the
  // first live response overrides it anyway.
  unawaited(ServerClock.I.restore());
  runApp(const MannaApp());
  // Sends whatever the phone kept, from any screen, as soon as it can — and
  // what was kept before a restart too (services/sync_engine.dart).
  SyncEngine.I.start();
}
