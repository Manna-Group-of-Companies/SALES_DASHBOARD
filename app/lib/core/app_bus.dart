
import 'package:flutter/material.dart';


// Global "something changed" bus. Any successful write notifies listeners so
// open screens (dashboard counts, targets, approvals…) reload automatically.
class AppBus extends ChangeNotifier {
  static final AppBus I = AppBus._();
  AppBus._();
  void bump() => notifyListeners();
}
