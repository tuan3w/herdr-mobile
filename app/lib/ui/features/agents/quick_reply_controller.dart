import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_transport.dart';

enum ReplyPhase {
  /// Nothing in flight; chips are tappable.
  idle,

  /// A destructive-looking option was tapped once; a second tap sends it.
  confirming,

  /// The request is on its way. Further taps are ignored.
  sending,

  /// Sent a moment ago; the card says so instead of offering the chips again.
  sent,

  /// The request failed; [QuickReplyController.error] says why.
  failed,
}

/// Sends answers to ONE pane from a card or the reply sheet: option chips
/// (their keys), typed text and single keys. Owns the small state machine the
/// UI shows inline: confirm-once for risky options, sending, "Sent: 1. Yes",
/// failure, and the guard against a second tap while one is in flight.
class QuickReplyController extends ChangeNotifier {
  QuickReplyController({
    required this.machine,
    required this.paneId,
    this.sentHold = const Duration(seconds: 3),
    this.confirmWindow = const Duration(seconds: 4),
    this.haptic = true,
  });

  final MachineConnection machine;
  final String paneId;

  /// How long "Sent: …" stays before the chips may be used again.
  final Duration sentHold;

  /// How long a confirm-once chip waits for its second tap.
  final Duration confirmWindow;
  final bool haptic;

  ReplyPhase _phase = ReplyPhase.idle;
  QuickReply? _confirming;
  QuickReply? _subject;
  String _sentLabel = '';
  String? _error;
  Timer? _timer;
  bool _disposed = false;

  ReplyPhase get phase => _phase;

  /// The option the current sending / sent / failed state is about (null for
  /// typed text and single keys), so its chip can carry the feedback.
  QuickReply? get subject => _subject;

  /// The chip waiting for its confirming tap, if any.
  QuickReply? get confirming => _confirming;

  /// What was sent, for "Sent: …".
  String get sentLabel => _sentLabel;
  String? get error => _error;
  bool get busy => _phase == ReplyPhase.sending;

  /// Taps an option. Returns true when it was sent.
  Future<bool> choose(QuickReply reply) {
    if (_phase == ReplyPhase.sending || _phase == ReplyPhase.sent) {
      return Future.value(false);
    }
    if (reply.needsConfirm && _confirming != reply) {
      _timer?.cancel();
      _confirming = reply;
      _error = null;
      _set(ReplyPhase.confirming);
      _timer = Timer(confirmWindow, cancelConfirm);
      return Future.value(false);
    }
    return _send(() => machine.api.sendKeys(paneId, reply.keys), reply.label, reply: reply);
  }

  /// Types [text] and presses enter. Whitespace alone only presses enter.
  Future<bool> sendLine(String text) => text.trim().isEmpty
      ? sendKey('enter')
      : _send(() => machine.api.sendLine(paneId, text), '“${_clip(text)}”');

  /// One herdr key (`esc`, `enter`, `up`, `down`). Moving through a menu is
  /// not an answer, so a key never locks the chips afterwards.
  Future<bool> sendKey(String key) =>
      _send(() => machine.api.sendKeys(paneId, [key]), key, hold: false);

  /// Gives up waiting for a second tap.
  void cancelConfirm() {
    if (_phase != ReplyPhase.confirming) return;
    _timer?.cancel();
    _confirming = null;
    _set(ReplyPhase.idle);
  }

  /// Clears a failure or leftover "Sent" so the chips show again.
  void reset() {
    if (_phase == ReplyPhase.sending) return;
    _timer?.cancel();
    _confirming = null;
    _error = null;
    _set(ReplyPhase.idle);
  }

  Future<bool> _send(
    Future<void> Function() action,
    String label, {
    QuickReply? reply,
    bool hold = true,
  }) async {
    if (_phase == ReplyPhase.sending) return false;
    _timer?.cancel();
    _confirming = null;
    _error = null;
    _subject = reply;
    _set(ReplyPhase.sending);
    try {
      await action();
    } on HerdrApiException catch (e) {
      return _fail(e.toString());
    } on HerdrTransportException catch (e) {
      return _fail(e.message);
    }
    if (_disposed) return true;
    if (haptic) unawaited(HapticFeedback.lightImpact());
    _sentLabel = label;
    if (!hold) {
      // A key press (navigating a menu) is not an answer: nothing to lock.
      _set(ReplyPhase.idle);
      return true;
    }
    _set(ReplyPhase.sent);
    _timer = Timer(sentHold, () {
      if (_phase == ReplyPhase.sent) _set(ReplyPhase.idle);
    });
    return true;
  }

  bool _fail(String message) {
    if (_disposed) return false;
    _error = message;
    _set(ReplyPhase.failed);
    return false;
  }

  void _set(ReplyPhase p) {
    _phase = p;
    if (p == ReplyPhase.idle || p == ReplyPhase.confirming) _subject = null;
    if (!_disposed) notifyListeners();
  }

  static String _clip(String s) {
    final line = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return line.length <= 24 ? line : '${line.substring(0, 23)}…';
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
