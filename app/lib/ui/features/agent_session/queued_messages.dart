import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/prompt_queue.dart';
import '../../../data/repositories/agent_session.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'session_select.dart';
import 'visible_text.dart';

/// Rows shown before "N more queued".
const queuedRowsShown = 3;

/// What waits to be sent, above the composer: one soft row per message, oldest
/// first. A tap opens it to edit or remove; the cross removes it. A message
/// the agent could not take now ([QueuedState.waiting]) goes out by itself
/// when the turn ends; after Stop, a failed turn or a refusal the messages are
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
      duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: queued.isEmpty ? const SizedBox(width: double.infinity) : _list(context, queued),
    ),
  );

  Widget _list(BuildContext context, List<QueuedMessage> queued) {
    final ds = context.ds;
    final held = [for (final m in queued) if (m.held) m];
    final shown = _all || queued.length <= queuedRowsShown ? queued : queued.take(queuedRowsShown).toList();
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
                  Icon(LucideIcons.pause, size: 14, color: ds.textSecondary),
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
                onRemove: () => widget.session.removeQueued(m.id),
              ),
            ),
          if (queued.length > queuedRowsShown)
            PressBuilder(
              onTap: () => setState(() => _all = !_all),
              builder: (context, pressed) => Container(
                constraints: const BoxConstraints(minHeight: kMinTap),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Text(
                  _all ? 'Show fewer' : '${queued.length - shown.length} more queued',
                  style: Type.label.copyWith(color: pressed ? ds.text : ds.textSecondary),
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
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final attachments = message.attachments.length;
    final note = [
      if (attachments > 0) '+ $attachments attachment${attachments == 1 ? '' : 's'}',
      ?reason,
    ].join(' · ');
    return DecoratedBox(
      decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.chip)),
      child: Row(
        children: [
          Expanded(
            child: PressBuilder(
              onTap: onEdit,
              builder: (context, pressed) => AnimatedContainer(
                duration: Motion.pressing(pressed),
                curve: Motion.easeOut,
                constraints: const BoxConstraints(minHeight: kMinTap),
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, 0, Gap.sm),
                decoration: BoxDecoration(
                  color: pressed ? ds.fillPressed : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(Radii.chip)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      message.held ? LucideIcons.pause : LucideIcons.clock,
                      size: 14,
                      color: ds.textSecondary,
                      semanticLabel: message.held ? 'Held' : 'Queued',
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
          ),
          CircleButton(
            icon: LucideIcons.x,
            tooltip: 'Remove queued message',
            size: 32,
            filled: false,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Opens queued message [id] to edit its text or remove it. A message that
/// went out meanwhile says so and can no longer be changed.
Future<void> editQueuedMessage(BuildContext context, AgentSessionView session, String id) =>
    showAppSheet<void>(context, builder: (_) => _EditQueued(session: session, id: id));

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
    _text = TextEditingController(text: _initial)
      ..selection = TextSelection.collapsed(offset: _initial.length);
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

  void _remove() {
    widget.session.removeQueued(widget.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final message = _message;
        final gone = message == null;
        final attachments = message?.attachments.length ?? 0;
        final changed = _text.text.trim().isNotEmpty && _text.text != _initial;
        return Padding(
          // Lifts the sheet over the keyboard.
          padding: EdgeInsets.fromLTRB(
            Gap.gutter,
            Gap.xl,
            Gap.gutter,
            Gap.lg + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text('Edit queued message', style: Type.title.copyWith(color: ds.text)),
              ),
              const SizedBox(height: Gap.lg),
              LabeledField(
                label: 'Message',
                controller: _text,
                minLines: 2,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                autofocus: true,
                helper: gone
                    ? 'Already sent. It can no longer be changed.'
                    : attachments > 0
                    ? '+ $attachments attachment${attachments == 1 ? '' : 's'} stay with it'
                    : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Gap.sm),
              Row(
                children: [
                  AppButton(
                    label: 'Remove',
                    kind: AppButtonKind.ghost,
                    onPressed: gone ? null : _remove,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: AppButton(
                      label: 'Save',
                      expand: true,
                      onPressed: gone || !changed ? null : _save,
                    ),
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
