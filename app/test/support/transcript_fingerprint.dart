import 'dart:convert';

import 'package:herdr_mobile/data/acp/session_state.dart';

/// Everything the transcript shows, as one comparable string.
String transcriptFingerprint(AgentSessionState s) {
  final b = StringBuffer();
  for (final i in s.items) {
    switch (i) {
      case TranscriptMessage():
        b.writeln('m ${i.key} ${i.role.name} ${i.messageId} ${jsonEncode(i.text)}');
      case TranscriptTool(:final call):
        b.writeln(
          't ${call.toolCallId} ${call.name} ${call.kind.name} ${call.status.name} ${jsonEncode(call.title)} '
          '${jsonEncode(call.rawInput)} ${jsonEncode(call.rawOutput)} '
          '${jsonEncode([for (final c in call.content) c.toJson()])} '
          '${[for (final l in call.locations) '${l.path}:${l.line}']}',
        );
      case TranscriptStop():
        b.writeln('s ${i.key} ${i.reason.name}');
      case TranscriptNote():
        b.writeln('n ${i.key} ${jsonEncode(i.text)}');
    }
  }
  b.writeln('plan ${[for (final p in s.plan) '${p.status.name}:${p.content}']}');
  b.writeln('title ${s.title}');
  return b.toString();
}
