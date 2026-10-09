import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/pane_answerer.dart' show promptDigest;
import '../../../data/repositories/pane_previews.dart';
import '../../../data/services/herdr_transport.dart';
import '../../core/motion.dart';

enum ReplyPhase {
  /// Nothing in flight; chips are tappable.
  idle,

  /// A destructive-looking option was activated once through the two-step
  /// (assistive) path; a second activation, or a hold, sends it.
  confirming,

  /// The request is on its way. Further taps are ignored.
  sending,

  /// Sent a moment ago; the card says so instead of offering the chips again.
  sent,

  /// The request failed; [QuickReplyController.error] says why.
  failed,

  /// Read again just before sending, the pane asked something else: nothing
  /// was sent, and the question it asks now is on screen.
  changed,
}

/// Sends answers to ONE pane from a card or the reply sheet: option chips
/// (their keys), typed text and single keys. Owns the small state machine the
/// UI shows inline: confirm-once for risky options (a hold, or two activations
/// for assistive technology), sending, "Sent: 1. Yes", failure, and the guard
/// against a second tap while one is in flight.
///
/// An option is never sent on the strength of what the screen showed: the
/// pane is read again first ([PanePreviews.recheck], one round trip, under the
/// chip's spinner) and the keys go only if it still asks the question the chip
/// was drawn for (`promptDigest`), as a notification's button does. The keys
/// are the ones read now: the cursor may have moved.
class QuickReplyController extends ChangeNotifier {
  QuickReplyController({
    required this.machine,
    required this.paneId,
    required this.previews,
    this.sentHold = const Duration(seconds: 3),
    this.confirmWindow = const Duration(seconds: 4),
    this.changedHold = const Duration(milliseconds: 1500),
    this.haptic = true,
  });

  final MachineConnection machine;
  final String paneId;

  /// Where the question is read again before an option is sent, and where the
  /// one read is shown.
  final PanePreviews previews;

  /// How long "Sent: …" stays before the chips may be used again.
  final Duration sentHold;

  /// How long a primed chip waits for its second activation (or a hold).
  final Duration confirmWindow;

  /// How long a chip says the question changed before it shows its option.
  final Duration changedHold;
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
  /// typed text and single keys), so its chip can carry the feedback. After
  /// [ReplyPhase.changed], the new question's option where the tapped one was.
  QuickReply? get subject => _subject;

  /// The chip primed and waiting for its second activation or a hold, if any.
  QuickReply? get confirming => _confirming;

  /// What was sent, for "Sent: …".
  String get sentLabel => _sentLabel;
  String? get error => _error;
  bool get busy => _phase == ReplyPhase.sending;

  /// Taps an option of [asked], the question its chip was drawn for. A gated
  /// one ([QuickReply.needsConfirm]) is primed by the first call and sent by
  /// the second: the path for assistive technology, which cannot hold (see
  /// [confirmByHold] for the pointer). Returns true when it was sent.
  Future<bool> choose(QuickReply reply, {required PromptInfo asked}) {
    if (_phase == ReplyPhase.sending || _phase == ReplyPhase.sent) {
      return Future.value(false);
    }
    if (reply.needsConfirm && _confirming != reply) {
      _timer?.cancel();
      _confirming = reply;
      _error = null;
      if (haptic) Haptics.armed();
      _set(ReplyPhase.confirming);
      _timer = Timer(confirmWindow, cancelConfirm);
      return Future.value(false);
    }
    final index = asked.replies.indexOf(reply);
    return _send(() async {
      final now = await previews.recheck(machine, paneId);
      if (now == null || index < 0 || index >= now.replies.length || promptDigest(now) != promptDigest(asked)) {
        throw _Changed(now, index);
      }
      // The digest does not cover the reasons (a cut command, a risky word
      // the question did not have): an answer that became a gated one since the
      // chip was drawn was not confirmed as one, and is not sent on that tap.
      if (now.replies[index].needsConfirm && !reply.needsConfirm) throw _Changed(now, index);
      await machine.api.sendKeys(paneId, now.replies[index].keys);
    }, reply.label, reply: reply);
  }

  /// A finger held a gated [reply] to the end: that is its confirmation. Primes
  /// it, so the [choose] that follows, in the same turn, sends. Does nothing
  /// while a request is in flight or answered.
  void confirmByHold(QuickReply reply) {
    if (_phase == ReplyPhase.sending || _phase == ReplyPhase.sent) return;
    _timer?.cancel();
    _confirming = reply;
    _error = null;
    _set(ReplyPhase.confirming);
  }

  /// Types [text] and presses enter. Whitespace alone only presses enter.
  Future<bool> sendLine(String text) => text.trim().isEmpty
      ? sendKey('enter')
      : _send(() => machine.api.sendLine(paneId, text), '“${_clip(text)}”');

  /// One herdr key (`esc`, `enter`, `up`, `down`). Moving through a menu is
  /// not an answer, so a key never locks the chips afterwards.
  Future<bool> sendKey(String key) =>
      _send(() => machine.api.sendKeys(paneId, [key]), key, hold: false);

  /// Gives up waiting for the second activation.
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
    } on _Changed catch (c) {
      return _changed(c);
    } on HerdrApiException catch (e) {
      return _fail(e.toString());
    } on HerdrTransportException catch (e) {
      return _fail(e.message);
    }
    // An answer is the person dealing with the agent: a finished one is
    // reviewed (a key press that only moves through a menu is not an answer).
    if (hold) machine.markReviewed(paneId);
    if (_disposed) return true;
    if (haptic) Haptics.sent();
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
    if (haptic) Haptics.failed();
    _set(ReplyPhase.failed);
    return false;
  }

  bool _changed(_Changed c) {
    if (_disposed) return false;
    final replies = c.now?.replies ?? const <QuickReply>[];
    // Said on the chip under the thumb: the new question's option in the place
    // of the one tapped.
    _subject = replies.isEmpty ? null : replies[math.min(math.max(c.index, 0), replies.length - 1)];
    if (haptic) Haptics.failed();
    _set(ReplyPhase.changed);
    _timer = Timer(changedHold, () {
      if (_phase == ReplyPhase.changed) _set(ReplyPhase.idle);
    });
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

/// The pane asks something else than the chip was drawn for: [now] is what it
/// asks (null: nothing the app can answer), [index] the tapped option's place.
class _Changed implements Exception {
  const _Changed(this.now, this.index);

  final PromptInfo? now;
  final int index;
}
