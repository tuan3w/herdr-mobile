import '../acp/acp_models.dart';
import '../models/pane_preview.dart';
import '../observed/observed_contracts.dart';
import '../repositories/command_risk.dart' show grantsStandingPermission;
import '../repositories/prompt_detector.dart' show isNegativeReply;

/// The value of the choice that stands for "something else" in a question's
/// form (the agent's question tool always offers it).
const askOtherValue = 'other';

/// The form field that holds question [index]'s choice.
String askFieldName(int index) => 'q$index';

/// The form field that holds question [index]'s own answer.
String askOtherFieldName(int index) => 'q${index}_other';

/// The form the person fills in for the agent's question tool call: one field
/// per question (a single choice or several), the choices' descriptions in
/// their titles, "Other" as the last choice with a text field after it.
ElicitationRequest askRequest(PendingAsk ask, {required String sessionId, required String agentLabel}) {
  final fields = <ElicitationField>[];
  final many = ask.questions.length > 1;
  for (final (i, q) in ask.questions.indexed) {
    final choices = [
      for (final (j, o) in q.options.indexed)
        EnumChoice(
          '$j',
          [
            o.label,
            if (q.recommended == j) '(recommended)',
            if (o.description.isNotEmpty) '— ${o.description}',
          ].join(' '),
        ),
      const EnumChoice(askOtherValue, 'Other (type your own)'),
    ];
    final title = many ? q.question : (q.multi ? 'Choose any' : 'Choose one');
    fields.add(
      q.multi
          ? MultiEnumField(
              name: askFieldName(i),
              title: title,
              options: choices,
              defaultValues: [if (q.recommended != null) '${q.recommended}'],
            )
          : EnumField(
              name: askFieldName(i),
              title: title,
              required: true,
              options: choices,
              defaultValue: q.recommended == null ? null : '${q.recommended}',
            ),
    );
    fields.add(StringField(name: askOtherFieldName(i), title: 'Your own answer', maxLength: 4000));
  }
  return ElicitationRequest(
    mode: 'form',
    message: many
        ? '$agentLabel has ${ask.questions.length} questions'
        : (ask.questions.isEmpty ? '$agentLabel has a question' : ask.questions.first.question),
    sessionId: sessionId,
    toolCallId: ask.toolCallId,
    schema: ElicitationSchema(fields: fields),
  );
}

/// What the person answered, by question; or why the form cannot be answered
/// as it stands.
class AskAnswers {
  const AskAnswers.ok(this.answers) : problem = null;
  const AskAnswers.problem(this.problem) : answers = const [];

  final List<AskAnswer> answers;
  final String? problem;
}

/// Reads the accepted form [content] of [askRequest] back into one
/// [AskAnswer] per question. A question left unanswered, or "Other" chosen
/// with no text, is a [AskAnswers.problem].
AskAnswers askAnswers(PendingAsk ask, Map<String, Object?> content) {
  final out = <AskAnswer>[];
  for (final (i, q) in ask.questions.indexed) {
    final raw = content[askFieldName(i)];
    final text = content[askOtherFieldName(i)];
    final own = text is String && text.trim().isNotEmpty ? text.trim() : null;
    // The text is typed into the agent's dialog: a line break would submit it
    // and put the rest in the next field or the agent's prompt.
    if (own != null && own.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
      return AskAnswers.problem('Your own answer to “${_short(q.question)}” must be one line, with no control characters.');
    }
    final chosen = raw is List ? [for (final v in raw) '$v'] : [if (raw != null) '$raw'];
    final wantsOther = chosen.contains(askOtherValue);
    final picked = <int>[];
    for (final v in chosen) {
      final n = int.tryParse(v);
      if (n != null && n >= 0 && n < q.options.length && !picked.contains(n)) picked.add(n);
    }
    picked.sort();
    if (wantsOther && own == null) {
      return AskAnswers.problem('Type your own answer to “${_short(q.question)}”, or choose another option.');
    }
    if (!q.multi && picked.isEmpty && !wantsOther) {
      return AskAnswers.problem('Choose an answer to “${_short(q.question)}”.');
    }
    out.add(AskAnswer(selected: picked, custom: wantsOther ? own : null));
  }
  return AskAnswers.ok(out);
}

String _short(String s) => s.length <= 60 ? s : '${s.substring(0, 59).trimRight()}…';

/// Whether the question tool's result text ([output], verbatim from the log)
/// says [answers] were recorded. One question: `User selected: a, b` and/or
/// `User provided custom input: text`. Several: `User answers:` then one
/// `id: label`, `id: [a, b]` or `id: "custom"` line per question (an own
/// answer wins over the options). Options are compared by label.
bool askResultMatches(String? output, PendingAsk ask, List<AskAnswer> answers) {
  if (output == null || answers.length != ask.questions.length || answers.isEmpty) return false;
  final lines = output.split('\n');
  List<String> labelsOf(int i) => [
    for (final j in answers[i].selected)
      if (j >= 0 && j < ask.questions[i].options.length) ask.questions[i].options[j].label,
  ];
  bool sameLabels(String text, List<String> want) {
    final got = [
      for (final p in _stripNotes(text).split(RegExp(r'\s*,\s*')))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    return got.length == want.length && got.toSet().containsAll(want);
  }

  if (ask.questions.length == 1) {
    const selected = 'User selected:';
    const custom = 'User provided custom input:';
    String? pickedText;
    String? customText;
    for (final l in lines) {
      if (l.startsWith(selected)) pickedText = l.substring(selected.length).trim();
      if (l.startsWith(custom)) customText = _stripNotes(l.substring(custom.length).trim());
    }
    final a = answers.first;
    final own = a.custom;
    if (own != null) return customText == own && (pickedText == null || sameLabels(pickedText, labelsOf(0)));
    return customText == null && pickedText != null && sameLabels(pickedText, labelsOf(0));
  }

  for (final (i, q) in ask.questions.indexed) {
    final prefix = '${q.id}:';
    String? value;
    for (final l in lines) {
      if (l.startsWith(prefix)) {
        value = l.substring(prefix.length).trim();
        break;
      }
    }
    if (value == null) return false;
    value = _stripNotes(value);
    final own = answers[i].custom;
    if (own != null) {
      if (value != '"$own"' && value != '“$own”') return false;
      continue;
    }
    final inner = value.startsWith('[') && value.endsWith(']') ? value.substring(1, value.length - 1) : value;
    if (!sameLabels(inner, labelsOf(i))) return false;
  }
  return true;
}

final _trailingNote = RegExp(r'\s*\((?:auto-selected after timeout|note:[^)]*)\)\s*$');

String _stripNotes(String s) {
  var out = s.trim();
  for (var m = _trailingNote.firstMatch(out); m != null; m = _trailingNote.firstMatch(out)) {
    out = out.substring(0, m.start).trim();
  }
  return out;
}

/// A question tool call's identity for keying its form: changes when the
/// questions do.
String askSignature(PendingAsk ask) => [
  ask.toolCallId,
  for (final q in ask.questions) ...[q.id, q.question, q.multi, for (final o in q.options) o.label],
].join('\u0001');

/// The permission request for a dialog [prompt] understood on the pane. The
/// title, kind and input are the log's open tool call's when there is one
/// (structured arguments beat scraped text), else the prompt's own subject.
/// Option [PermissionOption.optionId] is the reply's index.
PermissionRequest promptRequest(PromptInfo prompt, {required String paneId, ToolCall? call}) {
  final subject = prompt.subject.trim();
  final input = call == null ? null : _evidenceInput(call);
  final fields = <String, Object?>{
    'toolCallId': call?.toolCallId ?? 'prompt',
    'title': call != null && call.title.trim().isNotEmpty ? call.title : prompt.question,
    'kind': call == null ? 'other' : _kindWire(call.kind),
    if (input != null)
      'rawInput': input
    else if (subject.isNotEmpty)
      'rawInput': {'command': subject},
    // The change the call makes, as its diffs: what an edit approval shows.
    if (call != null && call.content.any((c) => c is ToolDiff)) 'content': [for (final c in call.content) c.toJson()],
    if (call != null && call.locations.isNotEmpty)
      'locations': [
        for (final l in call.locations) {'path': l.path, if (l.line != null) 'line': l.line},
      ],
  };
  return PermissionRequest(
    sessionId: paneId,
    toolCall: ToolCallPatch(call?.toolCallId ?? 'prompt', fields),
    title: prompt.question,
    options: [
      for (final (i, r) in prompt.replies.indexed)
        PermissionOption(
          optionId: '$i',
          name: replyName(r),
          kind: replyKind(r),
          // The detector's own judgement travels with the option: the dock
          // judges only what it shows, and a cut command or a second-tap
          // reason read from rows it does not show must still gate the tap.
          gate: r.needsConfirm ? r.risk ?? 'check it first' : null,
        ),
    ],
  );
}

/// [_flatInput] without what the card shows better another way: the change of
/// an edit (its diffs are sent) and the plan file's path (the plan itself is).
Object? _evidenceInput(ToolCall call) {
  final input = _flatInput(call);
  if (input is! Map) return input;
  final drop = <String>{
    if (call.content.any((c) => c is ToolDiff)) ...const ['old_string', 'new_string', 'content', 'patch', 'edits', 'file_path'],
    if (call.kind == ToolKind.switchMode) 'planFilePath',
  };
  if (drop.isEmpty) return input;
  return {for (final e in input.entries) if (!drop.contains(e.key)) e.key: e.value};
}

/// The call's arguments as the permission dock can read them. A `task` call
/// (subagents) has nested assignments, which have no flat reading: they are
/// written out one per subagent, so the person approves what each is asked.
Object? _flatInput(ToolCall call) {
  final input = call.rawInput;
  if (call.name != 'task' || input is! Map) return input;
  final tasks = input['tasks'];
  if (tasks is! List) return input;
  final lines = <String>[];
  for (final t in tasks) {
    if (t is! Map) continue;
    final name = t['name'] ?? t['id'] ?? 'subagent';
    final agent = t['agent'];
    final text = t['task'] ?? t['assignment'] ?? t['description'] ?? '';
    lines.add('$name${agent is String && agent.isNotEmpty ? ' ($agent)' : ''}: $text');
  }
  final context = input['context'];
  return {
    if (context is String && context.trim().isNotEmpty) 'context': context,
    'subagents': lines.join('\n\n'),
  };
}

String _kindWire(ToolKind k) => switch (k) {
  ToolKind.switchMode => 'switch_mode',
  _ => k.name,
};

final _numberPrefix = RegExp(r'^\s*\d{1,2}[.)]\s*');

/// The reply's words without the number in front.
String replyName(QuickReply r) {
  final name = r.label.replaceFirst(_numberPrefix, '').trim();
  return name.isEmpty ? r.label : name;
}

/// A refusal is a reject, a standing grant an `allow_always`, any other
/// answer an allow.
PermissionOptionKind replyKind(QuickReply r) {
  final standing = grantsStandingPermission(r.label);
  if (isNegativeReply(r)) return standing ? PermissionOptionKind.rejectAlways : PermissionOptionKind.rejectOnce;
  return standing ? PermissionOptionKind.allowAlways : PermissionOptionKind.allowOnce;
}

/// A key for a prompt: changes when the question, its subject or any reply's
/// words do. The keys are not part of it: they depend on where the cursor is,
/// and are read from the screen again when an answer is sent.
String promptSignature(PromptInfo p) => [
  p.question,
  p.subject,
  for (final r in p.replies) r.label,
].join('\u0001');
