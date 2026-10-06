import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart' show TranscriptItem;
import '../../../data/decision/permission_evidence.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/step_clock.dart';
import '../../core/tap_guard.dart';
import '../../core/theme.dart';
import '../settings/app_switch.dart';
import 'permission_evidence_view.dart';
import 'visible_text.dart';

/// The names of the form fields the agent marked secret (Codex's
/// `_meta.codex.isSecret`, a bare `_meta.isSecret`, or a password format).
/// The field is shown as any other, with a warning: a form is not a place
/// for secrets, and hiding the text would pretend it is.
Set<String> secretFields(ElicitationRequest request) {
  final schema = request.raw['requestedSchema'];
  final properties = schema is Map ? schema['properties'] : null;
  final out = <String>{};
  if (properties is Map) {
    properties.forEach((name, value) {
      if (name is! String || value is! Map) return;
      final meta = value['_meta'];
      final codex = meta is Map ? meta['codex'] : null;
      if ((codex is Map && codex['isSecret'] == true) ||
          (meta is Map && meta['isSecret'] == true) ||
          value['format'] == 'password') {
        out.add(name);
      }
    });
  }
  return out;
}

/// A short, sentence-case reason from a validation message.
String fieldError(String message) => message == 'required'
    ? 'Required'
    : message.isEmpty
        ? message
        : '${message[0].toUpperCase()}${message.substring(1)}';

/// What the person has put into one question and not sent yet, by field
/// name. It lives outside the panel (the dock keeps one per request) because
/// the panel does not always stay: a permission request that arrives takes
/// the dock and the question's panel goes; when the question shows again its
/// panel starts from here, so nothing typed is lost.
class QuestionDraft {
  final texts = <String, String>{};
  final bools = <String, bool>{};
  final single = <String, String?>{};
  final multi = <String, Set<String>>{};
}

/// The agent's question, docked above the composer as a form: its message,
/// one control per schema field, and Accept / Decline. Like a permission
/// request it ignores Accept and Decline for [tapGuard] after it appears, so
/// a tap meant for what was on screen before cannot answer it.
///
/// Only form requests are answered. A URL request (which this app never
/// offers) shows what it says and can only be declined.
class QuestionPanel extends StatefulWidget {
  const QuestionPanel({
    super.key,
    required this.request,
    required this.more,
    required this.onAnswer,
    this.items = const [],
    this.receivedAt,
    this.draft,
    this.now = DateTime.now,
  });

  final ElicitationRequest request;

  /// The transcript the question belongs to: the agent's last sentence before
  /// a plan approval is read from it, once.
  final List<TranscriptItem> items;

  /// Other requests waiting behind this one.
  final int more;
  final ValueChanged<ElicitationResponse> onAnswer;

  /// When the app received the request ([PendingQuestion.receivedAt]); the
  /// countdown of an auto-resolving question counts from here. Null: from
  /// when the panel appeared.
  final DateTime? receivedAt;

  /// Where the answers typed so far are kept, so a panel made again for the
  /// same request starts with them. Null: they live and die with the panel.
  final QuestionDraft? draft;

  /// The clock the countdown reads (tests replace it).
  final DateTime Function() now;

  @override
  State<QuestionPanel> createState() => _QuestionPanelState();
}

class _QuestionPanelState extends State<QuestionPanel> with TapGuardState<QuestionPanel> {
  late final QuestionDraft _draft = widget.draft ?? QuestionDraft();
  final _texts = <String, TextEditingController>{};
  late final _bools = _draft.bools;
  late final _single = _draft.single;
  late final _multi = _draft.multi;
  late final Set<String> _secret = secretFields(widget.request);

  /// An omp plan approval: the plan sits in the question's own message as
  /// plain lines. It is shown as Markdown under the question's first line;
  /// null for any other question.
  late final PermissionEvidence? _plan = planApprovalEvidence(widget.request, items: widget.items);
  bool _submitted = false;
  bool _sent = false;
  late final DateTime _arrived = widget.receivedAt ?? widget.now();

  /// The question as the person reads it: for a plan approval only its first
  /// paragraph (the plan below it is drawn as Markdown), else all of it.
  String get _heading {
    final message = widget.request.message;
    if (message.isEmpty) return 'The agent has a question';
    final gap = message.indexOf('\n\n');
    return visibleText(_plan == null || gap < 0 ? message : message.substring(0, gap).trim());
  }

  ElicitationSchema? get _schema => widget.request.mode == 'form' ? widget.request.schema : null;

  @override
  void initState() {
    super.initState();
    // A question is news, like a permission request.
    Haptics.armed();
    for (final f in _schema?.fields ?? const <ElicitationField>[]) {
      switch (f) {
        case StringField():
          _text(f.name, f.defaultValue ?? '');
        case NumberField():
          final d = f.defaultValue;
          _text(f.name, d == null ? '' : (d == d.truncate() ? '${d.truncate()}' : '$d'));
        case BooleanField():
          _bools.putIfAbsent(f.name, () => f.defaultValue ?? false);
        case EnumField():
          if (!_single.containsKey(f.name)) _single[f.name] = f.defaultValue;
        case MultiEnumField():
          _multi.putIfAbsent(f.name, () => {...f.defaultValues});
        case UnknownField():
          break;
      }
    }
  }

  /// The field [name]'s controller, starting from the draft (else [initial]),
  /// and writing every change back to it.
  void _text(String name, String initial) {
    final c = _texts[name] = TextEditingController(text: _draft.texts[name] ?? initial);
    c.addListener(() => _draft.texts[name] = c.text);
  }

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _content() {
    final out = <String, Object?>{};
    for (final f in _schema?.fields ?? const <ElicitationField>[]) {
      switch (f) {
        case StringField():
          final text = _texts[f.name]!.text;
          if (text.isNotEmpty) out[f.name] = text;
        case NumberField():
          final text = _texts[f.name]!.text.trim();
          if (text.isEmpty) break;
          final n = num.tryParse(text);
          out[f.name] = n == null || !n.isFinite ? text : (f.integer && n == n.truncate() ? n.toInt() : n);
        case BooleanField():
          out[f.name] = _bools[f.name] ?? false;
        case EnumField():
          final v = _single[f.name];
          if (v != null) out[f.name] = v;
        case MultiEnumField():
          final chosen = _multi[f.name] ?? const <String>{};
          final list = [
            for (final o in f.options)
              if (chosen.contains(o.value)) o.value,
          ];
          if (list.isNotEmpty) out[f.name] = list;
        case UnknownField():
          break;
      }
    }
    return out;
  }

  Map<String, String> get _errors => _submitted ? _schema!.validate(_content()) : const {};

  void _changed(VoidCallback change) => setState(change);

  void _accept() {
    if (_sent || !settled) return;
    setState(() => _submitted = true);
    if (_schema!.validate(_content()).isNotEmpty) {
      Haptics.tick();
      return;
    }
    Haptics.sent();
    setState(() => _sent = true);
    widget.onAnswer(ElicitationAccept(_content()));
  }

  void _decline() {
    if (_sent || !settled) return;
    Haptics.sent();
    setState(() => _sent = true);
    widget.onAnswer(const ElicitationDecline());
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final request = widget.request;
    final schema = _schema;
    final errors = _errors;
    final secrets = [
      for (final f in schema?.fields ?? const <ElicitationField>[])
        if (_secret.contains(f.name)) f.label,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ds.blockedWash,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(LucideIcons.circleHelp, size: 16, color: ds.blockedText),
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                _heading,
                                style: Type.prompt.copyWith(height: 1.4, fontWeight: FontWeight.w600, color: ds.text),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_plan case final plan?) ...[
                        if (plan.intent case final said?) EvidenceIntent(text: said),
                        const SizedBox(height: Gap.sm),
                        PlanEvidence(markdown: plan.planMarkdown!, preview: plan.planIsPreview),
                      ],
                      if (schema == null) ...[
                        const SizedBox(height: Gap.sm),
                        Text(
                          'The agent asked you to open a web page. This app does not open links an agent asks for, so you can only decline.',
                          style: Type.secondary.copyWith(color: ds.textSecondary),
                        ),
                      ] else ...[
                        if (schema.description != null && schema.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(schema.description!, style: Type.secondary.copyWith(color: ds.textSecondary)),
                        ],
                        if (secrets.isNotEmpty) ...[
                          const SizedBox(height: Gap.sm),
                          _SecretWarning(fields: secrets),
                        ],
                        for (final f in schema.fields) ...[
                          const SizedBox(height: Gap.md),
                          _FieldBlock(
                            field: f,
                            secret: _secret.contains(f.name),
                            error: errors[f.name],
                            controller: _texts[f.name],
                            boolValue: _bools[f.name],
                            single: _single[f.name],
                            multi: _multi[f.name],
                            onBool: (v) => _changed(() => _bools[f.name] = v),
                            onSingle: (v) => _changed(() => _single[f.name] = v),
                            onMulti: (v, on) => _changed(() {
                              final set = _multi[f.name]!;
                              on ? set.add(v) : set.remove(v);
                            }),
                            onText: () => _changed(() {}),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              if (schema != null && request.autoResolution != null) ...[
                const SizedBox(height: Gap.sm),
                AutoResolveLabel(deadline: _arrived.add(request.autoResolution!), now: widget.now),
              ],
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Decline',
                      kind: AppButtonKind.secondary,
                      expand: true,
                      onPressed: _sent || !settled ? null : _decline,
                    ),
                  ),
                  if (schema != null) ...[
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: AppButton(
                        label: 'Accept',
                        expand: true,
                        loading: _sent,
                        onPressed: _sent || !settled ? null : _accept,
                      ),
                    ),
                  ],
                ],
              ),
              if (widget.more > 0) ...[
                const SizedBox(height: Gap.sm),
                Text(
                  '${widget.more} more waiting',
                  style: Type.label.copyWith(color: ds.blockedText, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SecretWarning extends StatelessWidget {
  const _SecretWarning({required this.fields});

  final List<String> fields;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(LucideIcons.triangleAlert, size: 14, color: ds.dangerText),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'The agent marked ${fields.join(', ')} as secret. What you type here goes to the agent in plain text; it is not hidden. Don’t enter a password or key unless you accept that.',
            style: Type.secondary.copyWith(color: ds.dangerText),
          ),
        ),
      ],
    );
  }
}

class _FieldBlock extends StatelessWidget {
  const _FieldBlock({
    required this.field,
    required this.secret,
    required this.error,
    required this.controller,
    required this.boolValue,
    required this.single,
    required this.multi,
    required this.onBool,
    required this.onSingle,
    required this.onMulti,
    required this.onText,
  });

  final ElicitationField field;
  final bool secret;
  final String? error;
  final TextEditingController? controller;
  final bool? boolValue;
  final String? single;
  final Set<String>? multi;
  final ValueChanged<bool> onBool;
  final ValueChanged<String?> onSingle;
  final void Function(String value, bool on) onMulti;
  final VoidCallback onText;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final f = field;
    final label = f.label + (f.required ? '' : ' (optional)');
    final description = f.description;
    final errorText = error == null ? null : fieldError(error!);
    final hasDetails = f is! BooleanField && f is! UnknownField && ((description != null && description.isNotEmpty) || secret);
    final Widget? details = hasDetails
        ? Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (description != null && description.isNotEmpty)
                  Text(description, style: Type.secondary.copyWith(color: ds.textSecondary)),
                if (secret) Text('Marked secret by the agent', style: Type.caption.copyWith(color: ds.dangerText)),
              ],
            ),
          )
        : null;

    Widget control = switch (f) {
      StringField() => _TextControl(
        label: label,
        controller: controller!,
        error: errorText,
        multiline: f.format == null && (f.maxLength == null || f.maxLength! > 80),
        keyboard: switch (f.format) {
          'email' => TextInputType.emailAddress,
          'uri' => TextInputType.url,
          _ => TextInputType.text,
        },
        hint: f.format,
        details: details,
        onChanged: onText,
      ),
      NumberField() => _TextControl(
        label: label,
        controller: controller!,
        error: errorText,
        multiline: false,
        keyboard: TextInputType.numberWithOptions(decimal: !f.integer, signed: (f.minimum ?? 0) < 0),
        hint: switch ((f.minimum, f.maximum)) {
          (final lo?, final hi?) => '$lo to $hi',
          (final lo?, null) => 'at least $lo',
          (null, final hi?) => 'at most $hi',
          _ => f.integer ? 'whole number' : 'number',
        },
        onChanged: onText,
        details: details,
      ),
      BooleanField() => SwitchRow(title: f.label, subtitle: description, value: boolValue ?? false, onChanged: onBool),
      EnumField() => _Choices(
        title: label,
        multi: false,
        options: f.options,
        selected: {?single},
        onToggle: (value, on) => onSingle(on ? value : null),
        details: details,
      ),
      MultiEnumField() => _Choices(
        title: label,
        multi: true,
        options: f.options,
        selected: multi ?? const {},
        onToggle: onMulti,
        details: details,
        hint: switch ((f.minItems, f.maxItems)) {
          (final lo?, final hi?) => 'Choose $lo to $hi',
          (final lo?, null) => 'Choose at least $lo',
          (null, final hi?) => 'Choose up to $hi',
          _ => null,
        },
      ),
      UnknownField() => Text(
        '${f.label}: this app can’t show a field of type “${f.type}”.',
        style: Type.secondary.copyWith(color: ds.textMuted),
      ),
    };
    final isBool = f is BooleanField;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        control,
        if (errorText != null && (isBool || f is EnumField || f is MultiEnumField || f is UnknownField))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(errorText, style: Type.caption.copyWith(color: ds.dangerText)),
          ),
      ],
    );
  }
}

class _TextControl extends StatelessWidget {
  const _TextControl({
    required this.label,
    required this.controller,
    required this.error,
    required this.multiline,
    required this.keyboard,
    required this.onChanged,
    this.hint,
    this.details,
  });

  final String label;
  final TextEditingController controller;
  final String? error;
  final bool multiline;
  final TextInputType keyboard;
  final String? hint;
  final Widget? details;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text(label, style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600)),
          ),
        ),
        ?details,
        Semantics(
          label: label,
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: multiline ? 4 : 1,
            keyboardType: multiline ? TextInputType.multiline : keyboard,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => onChanged(),
            style: Type.body.copyWith(fontSize: 16, color: ds.text),
            cursorColor: ds.accent,
            decoration: InputDecoration(hintText: hint, errorText: error, errorMaxLines: 2),
          ),
        ),
      ],
    );
  }
}

/// Radio rows (one choice) or checkbox rows (several), each 44 high.
class _Choices extends StatelessWidget {
  const _Choices({
    required this.title,
    required this.multi,
    required this.options,
    required this.selected,
    required this.onToggle,
    this.hint,
    this.details,
  });

  final String title;
  final bool multi;
  final List<EnumChoice> options;
  final Set<String> selected;
  final void Function(String value, bool on) onToggle;
  final String? hint;
  final Widget? details;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(title, style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600)),
          ),
          ?details,
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(hint!, style: Type.caption.copyWith(color: ds.textMuted)),
            ),
          if (options.isEmpty)
            Text('No choices offered.', style: Type.secondary.copyWith(color: ds.textMuted)),
          for (final o in options)
            _ChoiceRow(
              label: o.title,
              multi: multi,
              selected: selected.contains(o.value),
              onTap: () => onToggle(o.value, !selected.contains(o.value)),
            ),
        ],
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.multi, required this.selected, required this.onTap});

  final String label;
  final bool multi;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      selected: selected,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: kMinTap),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: Row(
          children: [
            const SizedBox(width: 2),
            ExcludeSemantics(
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: multi ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: multi ? BorderRadius.circular(5) : null,
                  color: selected && multi ? ds.accent : Colors.transparent,
                  border: Border.all(color: selected ? ds.accent : ds.textTertiary, width: selected && !multi ? 2 : 1.5),
                ),
                alignment: Alignment.center,
                child: selected
                    ? (multi
                        ? Icon(LucideIcons.check, size: 14, color: ds.onAccent)
                        : Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: ds.accent)))
                    : null,
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Text(label, style: Type.body.copyWith(fontSize: 14.5, color: ds.text)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "The agent goes on without an answer within 45 s.": what Codex does when a
/// question waits too long (`_meta.codex.autoResolutionMs`). When the request
/// is withdrawn the panel goes, label and all.
///
/// The label moves once a second and only while it is on screen and the time
/// is not up: its own one-second [StepClock], leased through
/// [StepClockLease] (so it also stops in the background). Nothing animates.
/// The time is counted from when this app got the request, so "within" is the
/// honest word: after a re-attach the agent's own timer may be further along.
class AutoResolveLabel extends StatefulWidget {
  const AutoResolveLabel({super.key, required this.deadline, this.now = DateTime.now});

  final DateTime deadline;
  final DateTime Function() now;

  @override
  State<AutoResolveLabel> createState() => _AutoResolveLabelState();
}

class _AutoResolveLabelState extends State<AutoResolveLabel> with StepClockLease<AutoResolveLabel> {
  static final _second = StepClock(const Duration(seconds: 1));

  @override
  StepClock get clock => _second;

  @override
  bool get wantsClock => widget.deadline.isAfter(widget.now());

  @override
  void didUpdateWidget(AutoResolveLabel old) {
    super.didUpdateWidget(old);
    syncClock();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: clock.steps,
    builder: (context, _, _) {
      final left = widget.deadline.difference(widget.now());
      if (left <= Duration.zero) {
        // Time is up: stop the clock after this frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) syncClock();
        });
      }
      return Text(
        autoResolveWords(left),
        style: Type.secondary.copyWith(color: context.ds.textSecondary),
      );
    },
  );
}

/// The words for [left] time before an agent goes on without an answer.
String autoResolveWords(Duration left) {
  if (left <= Duration.zero) return 'The agent is going on without an answer.';
  final seconds = (left.inMilliseconds + 999) ~/ 1000;
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final span = minutes == 0 ? '$seconds s' : (rest == 0 ? '$minutes min' : '$minutes min $rest s');
  return 'The agent goes on without an answer within $span.';
}
