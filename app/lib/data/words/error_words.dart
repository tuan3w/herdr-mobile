import 'dart:async';

import '../services/herdr_transport.dart';

/// The one sentence a failure becomes for the person: what happened, then what
/// to do. Never a type name, an error code or a raw `toString()`; those belong
/// in logs. [machine] names the machine when the failure is about reaching it.
///
/// - A herdr error: its own message (herdr writes those for people), or a
///   sentence for a code it is known by.
/// - A fatal transport failure (bad credentials, changed host key, no bridge):
///   its message, because it already says what the person must change.
/// - Any other transport failure or a timeout: no connection or no answer;
///   Retry is the next step. Worded so it also reads after a prefix such as
///   `Couldn’t send:`.
/// - Anything else: a fixed sentence.
String describeError(Object error, {String? machine}) {
  final name = machine == null || machine.isEmpty ? 'the machine' : machine;
  return switch (error) {
    HerdrApiException(:final code, :final message) => _apiWords(code, message),
    HerdrTransportException(:final message, :final fatal) when fatal && message.trim().isNotEmpty => message,
    HerdrTransportException() => 'No connection to $name. Check it’s online, then Retry.',
    TimeoutException() => 'No answer from $name in time. Retry.',
    _ => 'Something unexpected stopped this. Retry.',
  };
}

String _apiWords(String code, String message) {
  switch (code) {
    case 'pane_not_found':
      return 'That pane is gone. Go back to the board.';
    case 'workspace_not_found':
      return 'That workspace is gone. Go back to the board.';
    case 'tab_not_found':
      return 'That tab is gone. Go back to the board.';
  }
  final text = message.trim();
  // herdr's own words, unless it sent nothing or a placeholder.
  if (text.isEmpty || text == 'unknown error') return 'herdr refused that. Retry.';
  return text;
}
