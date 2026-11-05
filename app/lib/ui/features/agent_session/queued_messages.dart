import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/prompt_queue.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'session_select.dart';
import '../../render/visible_text.dart';

/// Rows shown before "N more queued".
const queuedRowsShown = 3;

/// What waits to be sent, above the composer: one soft row per message, oldest
/// first. A tap opens it to edit or remove; the cross removes it. A message an
/// agent in a terminal has been sent while its turn runs, and has not read
/// yet, is a row above them with nothing to tap: it is in the terminal's own
/// queue, out of the phone's hands, and goes when the chat shows it. A message
/// the agent could not take now ([QueuedState.waiting]) goes out by itself
/// when the turn ends (after the person's own Stop, together as one message);
/// after a failed turn, a stop from elsewhere (not for an agent in a terminal:
/// the phone cannot tell it from a finished turn) or a refusal the messages are
/// held, and one bar says why and offers Resume. Takes no room when nothing
/// waits.
class QueuedMessages extends StatefulWidget {
  const QueuedMessages({super.key, required this.session});

  final AgentSessionView session;

  @override
  State<QueuedMessages> createState() => _QueuedMessagesState();
}

class _QueuedMessagesState extends State<QueuedMessages> {
  bool _all = false;

  @override
  Widget build(BuildContext context) => SessionSelect<List<QueuedMessage>>(
    session: widget.session,
    select: (s) => s.queued,
    // The session replaces the list whenever it changes.
    same: identical,
    builder: (context, queued) => AnimatedSize(
      duration: Motion.of(context, Motion.expand),
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: queued.isEmpty ? const SizedBox(width: double.infinity) : _list(context, queued),
    ),
  );

  Widget _list(BuildContext context, List<QueuedMessage> queued) {
    final ds = context.ds;
    // What the phone typed into a running terminal turn comes first (it is the
    // oldest) and is not counted as queued: it is out of the phone's hands.
    final sent = [
      for (final m in queued)
        if (m.sent) m,
    ];
    final waiting = [
      for (final m in queued)
        if (!m.sent) m,
    ];
    final held = [
      for (final m in waiting)
        if (m.held) m,
    ];
    final shown = _all || waiting.length <= queuedRowsShown ? waiting : waiting.take(queuedRowsShown).toList();
    final reason = held.isEmpty ? null : visibleText(held.first.heldReason ?? 'Held. Resume to send.');
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(
                children: [
                  Icon(LucideIcons.pause, size: IconSize.inline, color: ds.textSecondary),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      reason,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondary.copyWith(color: ds.textSecondary),
                    ),
                  ),
                  AppButton(
                    label: 'Resume',
                    kind: AppButtonKind.secondary,
                    compact: true,
                    onPressed: widget.session.resumeQueue,
                  ),
                ],
              ),
            ),
          for (final m in sent)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: _QueuedRow(key: ValueKey(m.id), message: m, reason: null, onEdit: null, onRemove: null),
            ),
          for (final m in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: _QueuedRow(
                key: ValueKey(m.id),
                message: m,
                // The bar above says why; a row says only what differs.
                reason: m.held && m.heldReason != held.first.heldReason && m.heldReason != null
                    ? visibleText(m.heldReason!)
                    : null,
                onEdit: () => unawaited(editQueuedMessage(context, widget.session, m.id)),
                onRemove: () => unawaited(_confirmRemove(context, widget.session, m.id)),
              ),
            ),
          if (waiting.length > queuedRowsShown)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextAction(
                  label: _all ? 'Show less' : '${waiting.length - shown.length} more queued',
                  tone: TextActionTone.quiet,
                  onTap: () => setState(() => _all = !_all),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _QueuedRow extends StatelessWidget {
  const _QueuedRow({
    super.key,
    required this.message,
    required this.reason,
    required this.onEdit,
    required this.onRemove,
  });

  final QueuedMessage message;
  final String? reason;

  /// Null for a message already typed into the terminal: it can be neither
  /// edited nor taken back from the phone.
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final attachments = message.attachments.length;
    final note = [
      if (message.sent) 'Sent to the terminal · not read yet',
      if (attachments > 0) '+ ${countOf(attachments, 'attachment')}',
      ?reason,
    ].join(' · ');
    return Panel(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        children: [
          Expanded(
            child: PressRow(
              onTap: onEdit,
              minHeight: kMinTap - 2 * Gap.xs,
              padding: const EdgeInsetsDirectional.fromSTEB(Gap.md - PressRow.inset, Gap.xs, 0, Gap.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    message.sent
                        ? LucideIcons.cornerDownRight
                        : message.held
                        ? LucideIcons.pause
                        : LucideIcons.clock,
                    size: IconSize.inline,
                    color: ds.textSecondary,
                    semanticLabel: message.sent
                        ? 'Sent'
                        : message.held
                        ? 'Held'
                        : 'Queued',
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          message.text.isEmpty ? 'Attachment' : visibleText(message.text),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Type.compact.copyWith(color: ds.text),
                        ),
                        if (note.isNotEmpty)
                          Text(
                            note,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Type.caption.copyWith(color: ds.textMuted),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (onRemove case final remove?)
            CircleButton(
              icon: LucideIcons.x,
              tooltip: 'Remove queued message',
              size: kMinTap - Gap.md,
              filled: false,
              onPressed: remove,
            ),
        ],
      ),
    );
  }
}

/// Asks before dropping queued message [id]. The session cannot put a message
/// back (it may have gone out, and its attachments with it), so an Undo is not
/// possible and the guard comes first. True when it was removed.
Future<bool> _confirmRemove(BuildContext context, AgentSessionView session, String id) async {
  final ok = await showConfirmSheet(
    context,
    title: 'Remove this queued message?',
    message: 'It won’t be sent. Its text and attachments are dropped.',
    confirmLabel: 'Remove',
  );
  if (ok) session.removeQueued(id);
  return ok;
}

/// Opens queued message [id] to edit its text or remove it. A message that
/// went out meanwhile says so and can no longer be changed.
Future<void> editQueuedMessage(BuildContext context, AgentSessionView session, String id) => showAppSheet<void>(
  context,
  builder: (_) => _EditQueued(session: session, id: id),
);

class _EditQueued extends StatefulWidget {
  const _EditQueued({required this.session, required this.id});

  final AgentSessionView session;
  final String id;

  @override
  State<_EditQueued> createState() => _EditQueuedState();
}

class _EditQueuedState extends State<_EditQueued> {
  late final TextEditingController _text;
  late final String _initial;

  QueuedMessage? get _message {
    for (final m in widget.session.queued) {
      if (m.id == widget.id) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initial = _message?.text ?? '';
    _text = TextEditingController(text: _initial)..selection = TextSelection.collapsed(offset: _initial.length);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    widget.session.editQueued(widget.id, _text.text);
    Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final nav = Navigator.of(context);
    if (!await _confirmRemove(context, widget.session, widget.id)) return;
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final message = _message;
        final gone = message == null;
        final attachments = message?.attachments.length ?? 0;
        final changed = _text.text.trim().isNotEmpty && _text.text != _initial;
        return SheetScaffold(
          title: 'Edit queued message',
          kind: SheetKind.form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Gap.sm),
              LabeledField(
                label: 'Message',
                prose: true,
                controller: _text,
                minLines: 2,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                autofocus: true,
                helper: gone
                    ? 'Already sent. It can no longer be changed.'
                    : attachments > 0
                    ? '+ ${countOf(attachments, 'attachment')} stay with it'
                    : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Gap.sm),
              Row(
                children: [
                  AppButton(label: 'Remove', kind: AppButtonKind.ghost, onPressed: gone ? null : _remove),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: AppButton(label: 'Save', expand: true, onPressed: gone || !changed ? null : _save),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
