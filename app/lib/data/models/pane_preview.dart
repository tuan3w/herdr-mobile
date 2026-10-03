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
  });

  /// Short chip text, e.g. `1. Yes`, `No`, `Enter`.
  final String label;

  /// Keys as accepted by `HerdrApi.sendKeys`, e.g. `['1', 'enter']`.
  final List<String> keys;

  /// The option (or the command it approves) looks destructive: the UI
  /// should ask for a second tap before sending.
  final bool needsConfirm;

  @override
  bool operator ==(Object other) =>
      other is QuickReply &&
      other.label == label &&
      other.needsConfirm == needsConfirm &&
      listEquals(other.keys, keys);

  @override
  int get hashCode => Object.hash(label, needsConfirm, Object.hashAll(keys));

  @override
  String toString() => 'QuickReply($label, $keys${needsConfirm ? ', confirm' : ''})';
}

/// A question a blocked agent is waiting on, with one-tap answers.
@immutable
class PromptInfo {
  const PromptInfo({required this.question, required this.replies});

  /// One or two lines (joined by `\n`), ready to show.
  final String question;

  /// In on-screen order; never empty.
  final List<QuickReply> replies;

  @override
  bool operator ==(Object other) =>
      other is PromptInfo &&
      other.question == question &&
      listEquals(other.replies, replies);

  @override
  int get hashCode => Object.hash(question, Object.hashAll(replies));

  @override
  String toString() => 'PromptInfo($question, $replies)';
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
