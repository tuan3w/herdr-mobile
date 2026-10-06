import 'dart:collection';

import '../models/herdr_models.dart' show AgentStatus;
import '../models/pane_preview.dart';
import '../services/herdr_api.dart' show HerdrApiExceptionX;
import '../services/herdr_transport.dart' show HerdrApiException;
import '../services/notifier.dart' show NotificationAnswer;
import 'command_risk.dart' show grantsStandingPermission;
import 'machine_connection.dart';
import 'pane_previews.dart' show previewRows;
import 'prompt_detector.dart' show detectPrompt;

/// Rows read from a pane to find its question: what the cards read.
const _readLines = 24;

/// A 64-bit fingerprint (16 hex digits) of what a question shows the person: the
/// question, what it is about and the words of every option. Not the keys of an
/// option, which depend on where the cursor is and are read again when an
/// answer is sent. Two questions with one fingerprint read the same.
String promptDigest(PromptInfo prompt) {
  var a = 0x811c9dc5;
  var b = 0x050c5d1f;
  void add(int unit) {
    a = ((a ^ unit) * 0x01000193) & 0xffffffff;
    b = ((b ^ unit) * 0x01000193) & 0xffffffff;
    b = ((b << 5) | (b >> 27)) & 0xffffffff;
  }

  void addText(String s) {
    for (final unit in s.codeUnits) {
      add(unit);
    }
    add(1);
  }

  addText(prompt.question);
  addText(prompt.subject);
  for (final r in prompt.replies) {
    addText(r.label);
  }
  return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
}

/// Whether a notification may carry [reply] as a button: one tap must be the
/// whole answer. Anything the card makes the person confirm (a risky command,
/// a standing grant) is not.
bool answerableFromNotification(QuickReply reply) =>
    !reply.needsConfirm && !grantsStandingPermission(reply.label);

/// How a notification's answer ended.
enum AnswerOutcome {
  /// The keys went to the pane.
  sent,

  /// The pane no longer asks this question (or asks it differently, or the
  /// option now needs a second tap): nothing was sent.
  changed,

  /// The machine could not be reached: nothing was sent.
  unreachable,

  /// The same button was pressed twice, or another answer for the pane is on
  /// its way: nothing more was sent.
  duplicate,
}

/// Answers a terminal agent's question from outside the screens (a button on a
/// notification). It never trusts what the notification showed: it reads the
/// pane's screen again on the machine's existing connection, and sends only if
/// the question is still the one the button was made for and its option is
/// still a one-tap answer.
class PaneAnswerer {
  PaneAnswerer({required this._connection});

  final MachineConnection? Function(String machineId) _connection;

  /// Buttons already pressed, so one that is delivered twice answers once.
  final LinkedHashSet<String> _used = LinkedHashSet();
  final Set<String> _busy = {};

  /// The question [paneId] shows now, read from its screen; null when the pane
  /// is not blocked, shows nothing the app understands, or cannot be read.
  Future<PromptInfo?> promptOf(String machineId, String paneId) async {
    final conn = _connection(machineId);
    if (conn == null || !conn.isLive) return null;
    try {
      return await _read(conn, paneId);
    } on Object {
      return null;
    }
  }

  /// Sends [answer] if it still holds; see [AnswerOutcome].
  Future<AnswerOutcome> answer(NotificationAnswer answer) async {
    final pane = '${answer.machineId}/${answer.paneId}';
    if (_used.contains(answer.nonce) || !_busy.add(pane)) return AnswerOutcome.duplicate;
    // Taken before anything is sent: if the send fails halfway the button
    // must not be tried again.
    _used.add(answer.nonce);
    while (_used.length > 64) {
      _used.remove(_used.first);
    }
    try {
      final conn = _connection(answer.machineId);
      if (conn == null || !conn.isLive) return AnswerOutcome.unreachable;
      final PromptInfo? prompt;
      try {
        prompt = await _read(conn, answer.paneId);
      } on HerdrApiException catch (e) {
        return e.isNotFound ? AnswerOutcome.changed : AnswerOutcome.unreachable;
      } on Object {
        return AnswerOutcome.unreachable;
      }
      if (prompt == null || promptDigest(prompt) != answer.digest) return AnswerOutcome.changed;
      if (answer.index >= prompt.replies.length) return AnswerOutcome.changed;
      final reply = prompt.replies[answer.index];
      if (!answerableFromNotification(reply)) return AnswerOutcome.changed;
      try {
        await conn.api.sendKeys(answer.paneId, reply.keys);
      } on Object {
        return AnswerOutcome.unreachable;
      }
      // An answer is the person dealing with the agent, as in the card.
      conn.markReviewed(answer.paneId);
      return AnswerOutcome.sent;
    } finally {
      _busy.remove(pane);
    }
  }

  Future<PromptInfo?> _read(MachineConnection conn, String paneId) async {
    final read = await conn.api.readPane(paneId, lines: _readLines);
    // Only a pane the machine reports as blocked has a question to answer.
    final pane = conn.snapshot.panes.where((p) => p.id == paneId).firstOrNull;
    if (pane == null || pane.status != AgentStatus.blocked) return null;
    return detectPrompt(previewRows(read.text, maxLength: 160, keep: _readLines));
  }
}
