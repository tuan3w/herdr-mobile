import 'package:flutter/foundation.dart';

/// One row of a terminal preview: ANSI-stripped, trailing spaces trimmed and
/// capped in length.
@immutable
class PreviewLine {
  const PreviewLine(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is PreviewLine && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

/// One tap-to-answer option of a [PromptInfo].
@immutable
class QuickReply {
  const QuickReply({
    required this.label,
    required this.keys,
    this.needsConfirm = false,
    this.risk,
  }) : assert(risk == null || needsConfirm, 'a risk reason needs the second tap');

  /// Short chip text, e.g. `1. Yes`, `No`, `Enter`.
  final String label;

  /// Keys as accepted by `HerdrApi.sendKeys`, e.g. `['1', 'enter']`.
  final List<String> keys;

  /// The option (or the command it approves) deserves a second look: the UI
  /// asks for a second tap before sending.
  final bool needsConfirm;

  /// A few words naming why the second tap is needed ("pushes to a remote",
  /// "standing permission"); shown on the confirming chip. Null when the
  /// reason is unknown or no confirmation is needed.
  final String? risk;

  @override
  bool operator ==(Object other) =>
      other is QuickReply &&
      other.label == label &&
      other.needsConfirm == needsConfirm &&
      other.risk == risk &&
      listEquals(other.keys, keys);

  @override
  int get hashCode => Object.hash(label, needsConfirm, risk, Object.hashAll(keys));

  @override
  String toString() =>
      'QuickReply($label, $keys${needsConfirm ? ', confirm' : ''}${risk == null ? '' : ': $risk'})';
}

/// A question a blocked agent is waiting on, with one-tap answers.
@immutable
class PromptInfo {
  const PromptInfo({required this.question, required this.replies, this.subject = ''});

  /// One or two lines (joined by `\n`), ready to show.
  final String question;

  /// What the question is about, as the agent drew it: the command, URL or
  /// path being approved, rows joined by `\n` (at most 6, each at most 160
  /// characters; a cut row or a sixth row with more below ends in `…`).
  /// Empty when the screen shows none (an edit dialog names the file in the
  /// question).
  final String subject;

  /// In on-screen order; never empty.
  final List<QuickReply> replies;

  @override
  bool operator ==(Object other) =>
      other is PromptInfo &&
      other.question == question &&
      other.subject == subject &&
      listEquals(other.replies, replies);

  @override
  int get hashCode => Object.hash(question, subject, Object.hashAll(replies));

  @override
  String toString() => 'PromptInfo($question, ${subject.isEmpty ? '' : '$subject, '}$replies)';
}

/// The tail of a pane's terminal, as shown on a card or tab.
@immutable
class PanePreview {
  const PanePreview({
    required this.lines,
    required this.updatedAt,
    this.prompt,
  });

  /// Last (at most 8) non-empty rows, oldest first.
  final List<PreviewLine> lines;

  /// Set only while the agent is blocked and the screen ends in a prompt we
  /// understand.
  final PromptInfo? prompt;

  /// When the content last changed, as observed by this app. An idle pane's
  /// preview keeps its old [updatedAt]: the time is "since it last moved".
  final DateTime updatedAt;

  /// Same rows and prompt; [updatedAt] is deliberately ignored, so listeners
  /// only wake for something visible.
  bool sameContent(PanePreview other) =>
      listEquals(lines, other.lines) && prompt == other.prompt;

  @override
  bool operator ==(Object other) =>
      other is PanePreview &&
      other.updatedAt == updatedAt &&
      sameContent(other);

  @override
  int get hashCode => Object.hash(updatedAt, prompt, Object.hashAll(lines));
}
