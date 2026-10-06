import 'dart:async';

import 'package:flutter/widgets.dart';

/// A control that appears under the thumb, or moves under it, ignores answers
/// for this long and is drawn dimmed meanwhile: a tap meant for what was there
/// before, or the second tap of the answer just given, must not land on a new
/// question's Allow.
const tapGuard = Duration(milliseconds: 450);

/// For a panel that is keyed by what it asks: [settled] turns true [tapGuard]
/// after the panel is built and stays true. Answers must check it.
mixin TapGuardState<T extends StatefulWidget> on State<T> {
  bool _settled = false;
  Timer? _guardTimer;

  /// True once the panel may take answers.
  bool get settled => _settled;

  @override
  void initState() {
    super.initState();
    rearmGuard();
  }

  /// Starts the guard again: [settled] is false for [tapGuard] more. For a
  /// control that moved under the thumb while it stayed mounted. Call it from
  /// `didUpdateWidget`, before the rebuild.
  @protected
  void rearmGuard() {
    _guardTimer?.cancel();
    _settled = false;
    _guardTimer = Timer(tapGuard, () {
      if (mounted) setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    _guardTimer?.cancel();
    super.dispose();
  }
}

/// A gate that closes for [window] each time [arm] is called, for a list whose
/// answers move: when a card above them leaves or arrives, the answer under
/// the thumb is no longer the one that was there a moment ago.
///
/// [arm] may be called while building: [closed] is true at once, so everything
/// built after the call in the same frame already sees it, and the listeners
/// are told after the frame. They are told again when the gate opens.
class SettleGate extends ChangeNotifier {
  SettleGate({this.window = tapGuard});

  final Duration window;
  bool _closed = false;
  bool _disposed = false;
  Timer? _timer;

  /// True while answers must be ignored.
  bool get closed => _closed;

  /// Closes the gate (again) for [window].
  void arm() {
    _timer?.cancel();
    _timer = Timer(window, () {
      _closed = false;
      notifyListeners();
    });
    if (_closed) return;
    _closed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
