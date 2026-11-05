import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// How far a component is along: [stable] has a catalog entry, a semantics
/// test in `test/ui/core_controls_test.dart` and its row in docs/DESIGN.md.
enum KitStatus { stable, beta, deprecated }

/// One state of a component, drawn on its own under its [label].
class KitState {
  const KitState(this.label, this.build, {this.bleed = false});

  final String label;
  final WidgetBuilder build;

  /// The state runs edge to edge (rows, bars, sheets bring their own gutter).
  final bool bleed;
}

/// A kit component (or a token sheet) and the states it is shown in.
class KitEntry {
  const KitEntry(this.name, this.status, this.states, {this.tokens = false});

  final String name;
  final KitStatus status;
  final List<KitState> states;

  /// A token sheet rather than a component.
  final bool tokens;

  /// The name as a file name: `AnswerChip` -> `answerchip`, `Type ramp` -> `type-ramp`.
  String get slug => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
}

// Worst-case words: long English and Vietnamese (diacritics stack above and
// below the line, and the words are long once they wrap).
const _long = 'Refactor the retry policy in the SSH transport so a dropped link resumes';
const _vi = 'Sửa lỗi kết nối lại khi máy chủ SSH ngắt giữa chừng và tiếp tục phiên làm việc';
const _viShort = 'Cần bạn xử lý';

void _noop() {}
void _noopBool(bool _) {}

/// Every kit component and token sheet, in the order the Kit screen lists them.
final List<KitEntry> kitCatalog = [
  // Token sheets.
  KitEntry('Type ramp', KitStatus.stable, [
    for (final (name, style) in _typeRoles) KitState(name, (c) => _TypeSample(name: name, style: style)),
  ], tokens: true),
  KitEntry('Mono ramp', KitStatus.stable, [
    for (final (name, style) in _monoRoles) KitState(name, (c) => _TypeSample(name: name, style: style)),
  ], tokens: true),
  KitEntry('Colour roles', KitStatus.stable, [
    KitState('Contrast on bg', (c) => const _ColourSheet(), bleed: true),
  ], tokens: true),
  KitEntry('Radii', KitStatus.stable, [KitState('The five radii', (c) => const _RadiusSheet())], tokens: true),
  KitEntry('IconSize', KitStatus.stable, [KitState('The seven sizes', (c) => const _IconSheet())], tokens: true),
  KitEntry('HerdrIcons', KitStatus.beta, [
    KitState('The drawn set at nav size', (c) => const _HerdrIconSheet(size: IconSize.nav)),
    KitState('At row size', (c) => const _HerdrIconSheet(size: IconSize.row)),
  ], tokens: true),
  KitEntry('Gap', KitStatus.stable, [KitState('The spacing scale', (c) => const _GapSheet())], tokens: true),
  KitEntry('Motion', KitStatus.stable, [
    KitState('Tap to play a ${Motion.travel.round()} dp move', (c) => const _MotionSheet()),
  ], tokens: true),

  // Buttons and words to tap.
  KitEntry('AppButton', KitStatus.stable, [
    for (final kind in AppButtonKind.values)
      KitState(kind.name, (c) => AppButton(label: 'Start session', kind: kind, onPressed: _noop)),
    KitState(
      'with icon, expanded',
      (c) => const AppButton(label: 'Add machine', icon: LucideIcons.plus, expand: true, onPressed: _noop),
    ),
    KitState(
      'compact',
      (c) => const Align(
        alignment: AlignmentDirectional.centerStart,
        child: AppButton(label: 'Retry', compact: true, onPressed: _noop),
      ),
    ),
    KitState('loading', (c) => const AppButton(label: 'Connecting', loading: true, onPressed: _noop)),
    KitState('disabled', (c) => const AppButton(label: 'Start session', onPressed: null)),
    KitState('long Vietnamese label', (c) => const AppButton(label: _vi, expand: true, onPressed: _noop)),
  ]),
  KitEntry('CircleButton', KitStatus.stable, [
    KitState(
      'filled, active, bare, disabled',
      (c) => const Wrap(
        spacing: Gap.sm,
        children: [
          CircleButton(icon: LucideIcons.plus, tooltip: 'Add', onPressed: _noop),
          CircleButton(icon: LucideIcons.textWrap, tooltip: 'Wrap lines', active: true, onPressed: _noop),
          CircleButton(icon: LucideIcons.ellipsis, tooltip: 'More', filled: false, onPressed: _noop),
          CircleButton(icon: HerdrIcons.folder, tooltip: 'Files', onPressed: null),
        ],
      ),
    ),
    KitState(
      'with a mark (an update behind Settings)',
      (c) => const CircleButton(
        icon: HerdrIcons.settings,
        tooltip: 'Settings',
        mark: true,
        markLabel: 'update available',
        onPressed: _noop,
      ),
    ),
  ]),
  KitEntry('TextAction', KitStatus.beta, [
    KitState(
      'accent and quiet',
      (c) => const Wrap(
        spacing: Gap.lg,
        children: [
          TextAction(label: 'Read all', onTap: _noop),
          TextAction(label: 'Cancel request', tone: TextActionTone.quiet, onTap: _noop),
        ],
      ),
    ),
    KitState(
      'Vietnamese',
      (c) => const Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextAction(label: 'Xem tất cả', onTap: _noop),
      ),
    ),
  ]),

  // Choosing.
  KitEntry('AppChip', KitStatus.stable, [
    KitState(
      'rest, selected, tint',
      (c) => Wrap(
        spacing: Gap.sm,
        children: [
          const AppChip(label: 'All', onTap: _noop),
          const AppChip(label: 'Working', selected: true, onTap: _noop),
          AppChip(label: 'Failed', tint: c.ds.dangerText, onTap: _noop),
        ],
      ),
    ),
    KitState(
      'with icon, leading glyph, count',
      (c) => const Wrap(
        spacing: Gap.sm,
        children: [
          AppChip(label: 'Claude Code', icon: LucideIcons.bot, onTap: _noop),
          AppChip(
            label: 'Needs you',
            leading: StatusGlyph(status: AgentStatus.blocked, size: IconSize.inline),
            count: 3,
            selected: true,
            onTap: _noop,
          ),
          AppChip(label: 'Done', count: 12, onTap: _noop),
        ],
      ),
    ),
    KitState(
      'Vietnamese',
      (c) => const Wrap(
        spacing: Gap.sm,
        children: [
          AppChip(label: _viShort, count: 2, selected: true, onTap: _noop),
          AppChip(label: 'Đang chạy', onTap: _noop),
        ],
      ),
    ),
  ]),
  KitEntry('Segmented', KitStatus.stable, [
    KitState(
      'two options',
      (c) => _Live<int>(
        1,
        (c, v, set) => Segmented<int>(
          value: v,
          onChanged: set,
          options: const [SegmentOption(1, 'Rendered'), SegmentOption(2, 'Source')],
        ),
      ),
    ),
    KitState(
      'counts, too wide: it scrolls',
      (c) => _Live<int>(
        2,
        (c, v, set) => Segmented<int>(
          value: v,
          onChanged: set,
          options: const [
            SegmentOption(1, 'Pictures', count: 4),
            SegmentOption(2, 'Pages', count: 17),
            SegmentOption(3, 'Apps', count: 2),
            SegmentOption(4, 'Tệp đã thay đổi', count: 120),
          ],
        ),
      ),
    ),
  ]),
  KitEntry('AppSwitch / SwitchRow', KitStatus.beta, [
    KitState(
      'off and on',
      (c) => const Wrap(spacing: Gap.lg, children: [AppSwitch(value: false), AppSwitch(value: true)]),
    ),
    KitState(
      'row',
      (c) => _Live<bool>(
        true,
        (c, v, set) => SwitchRow(
          title: 'Wrap lines',
          subtitle: 'Long lines continue on the next line instead of scrolling sideways.',
          value: v,
          onChanged: set,
        ),
      ),
      bleed: true,
    ),
    KitState(
      'disabled, Vietnamese',
      (c) => const SwitchRow(
        title: 'Thông báo khi tác tử cần bạn',
        subtitle: _vi,
        value: false,
        onChanged: _noopBool,
        enabled: false,
      ),
      bleed: true,
    ),
  ]),
  KitEntry('LabeledField', KitStatus.stable, [
    KitState(
      'hint and helper',
      (c) => const LabeledField(
        label: 'Host',
        hint: 'build.example.com',
        helper: 'A name or an address the phone can reach.',
      ),
    ),
    KitState('mono', (c) => const LabeledField(label: 'Command', hint: 'herdr attach', mono: true)),
    KitState(
      'error',
      (c) => Form(
        autovalidateMode: AutovalidateMode.always,
        child: LabeledField(
          label: 'Port',
          hint: '22',
          validator: (_) => 'Couldn’t read a port: use a number from 1 to 65535.',
        ),
      ),
    ),
    KitState('Vietnamese', (c) => const LabeledField(label: 'Tên máy', helper: _vi)),
  ]),
  KitEntry('SearchField', KitStatus.beta, [
    KitState('empty', (c) => const SearchField(hint: 'Search sessions')),
    KitState(
      'with text: clear button',
      (c) => SearchField(
        hint: 'Find in src',
        controller: TextEditingController(text: 'retry'),
      ),
    ),
    KitState('Vietnamese', (c) => const SearchField(hint: 'Tìm trong thư mục dự án')),
  ]),
  KitEntry('KeyCap', KitStatus.beta, [
    KitState(
      'rest, icon, active, disabled',
      (c) => const Wrap(
        spacing: Gap.sm,
        children: [
          KeyCap(label: 'esc', onTap: _noop),
          KeyCap(icon: LucideIcons.arrowUp, semanticLabel: 'Up', onTap: _noop),
          KeyCap(label: 'ctrl', active: true, onTap: _noop),
          KeyCap(label: 'tab', onTap: null),
        ],
      ),
    ),
  ]),
  KitEntry('SelectMark', KitStatus.beta, [
    KitState(
      'circle: off, on, numbered',
      (c) => const Wrap(
        spacing: Gap.md,
        children: [SelectMark(selected: false), SelectMark(selected: true), SelectMark(selected: true, number: 3)],
      ),
    ),
    KitState(
      'square: off, on',
      (c) => const Wrap(
        spacing: Gap.md,
        children: [
          SelectMark(selected: false, shape: SelectMarkShape.square),
          SelectMark(selected: true, shape: SelectMarkShape.square),
        ],
      ),
    ),
    KitState(
      'on a photo',
      (c) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [c.ds.accent, c.ds.blocked]),
          borderRadius: BorderRadius.circular(Radii.xs),
        ),
        child: const Padding(
          padding: EdgeInsets.all(Gap.md),
          child: Wrap(
            spacing: Gap.md,
            children: [
              SelectMark(selected: false, onPhoto: true, size: SelectMark.photoSize),
              SelectMark(selected: true, number: 12, onPhoto: true, size: SelectMark.photoSize),
            ],
          ),
        ),
      ),
    ),
  ]),

  // Counts and status.
  KitEntry('CountBadge', KitStatus.beta, [
    for (final tone in CountTone.values)
      KitState(
        tone.name,
        (c) => Wrap(
          spacing: Gap.md,
          children: [
            for (final n in const [1, 12, 120]) CountBadge(count: n, tone: tone),
          ],
        ),
      ),
    KitState(
      'with a ring',
      (c) => ColoredBox(
        color: c.ds.accentWash,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: CountBadge(count: 3, ring: c.ds.surface),
          ),
        ),
      ),
    ),
  ]),
  KitEntry('RollText', KitStatus.beta, [
    KitState(
      'tap to count up',
      (c) => _Live<int>(
        2,
        (c, v, set) => Row(
          children: [
            RollText(
              text: needYou(v),
              style: Type.labelStrong.copyWith(color: c.ds.blockedText),
            ),
            const Spacer(),
            TextAction(label: 'Add one', onTap: () => set(v + 1)),
          ],
        ),
      ),
    ),
  ]),
  KitEntry('StatusGlyph', KitStatus.beta, [
    KitState(
      'every status, named',
      (c) => Wrap(
        spacing: Gap.lg,
        runSpacing: Gap.sm,
        children: [
          for (final s in AgentStatus.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusGlyph(status: s, size: IconSize.lead),
                const SizedBox(width: Gap.xs),
                Text(s.label, style: Type.label.copyWith(color: s.textColor(c.ds))),
              ],
            ),
          // A call, run or plan step that ended without being done.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StatusGlyph.failed(size: IconSize.lead),
              const SizedBox(width: Gap.xs),
              Text('Failed', style: Type.label.copyWith(color: c.ds.dangerText)),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StatusGlyph.cancelled(size: IconSize.lead),
              const SizedBox(width: Gap.xs),
              Text('Cancelled', style: Type.label.copyWith(color: c.ds.textSecondary)),
            ],
          ),
        ],
      ),
    ),
    KitState('stale (dim)', (c) => const StatusGlyph(status: AgentStatus.working, size: IconSize.lead, dim: true)),
  ]),
  KitEntry('LinkDot', KitStatus.beta, [
    KitState(
      'every link state',
      (c) => Wrap(
        spacing: Gap.lg,
        runSpacing: Gap.sm,
        children: [
          for (final s in LinkState.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinkDot(state: s),
                const SizedBox(width: Gap.sm),
                Text(s.label, style: Type.label.copyWith(color: s.textColor(c.ds))),
              ],
            ),
        ],
      ),
    ),
  ]),
  KitEntry('IconTile', KitStatus.beta, [
    KitState(
      'neutral and tinted',
      (c) => Wrap(
        spacing: Gap.md,
        children: [
          const IconTile(icon: LucideIcons.palette),
          IconTile(icon: LucideIcons.bellOff, color: c.ds.blocked),
          IconTile(icon: LucideIcons.download, color: c.ds.accent),
        ],
      ),
    ),
  ]),

  // Rows.
  KitEntry('ListRow', KitStatus.stable, [
    KitState(
      'agent row',
      (c) => ListRow(
        leading: const StatusGlyph(status: AgentStatus.blocked, size: IconSize.lead),
        title: 'Fix flaky retry test',
        subtitle: 'Claude Code · build-box · herdr-mobile',
        trailing: Text('4m', style: Type.captionStrong.copyWith(color: c.ds.blockedText)),
        onTap: _noop,
      ),
      bleed: true,
    ),
    KitState(
      'long title wraps to two lines',
      (c) => ListRow(
        leading: const StatusGlyph(status: AgentStatus.working, size: IconSize.lead),
        title: _long,
        subtitle: 'Codex · build-box',
        trailing: Text('12s', style: Type.caption.copyWith(color: c.ds.textMuted)),
        onTap: _noop,
      ),
      bleed: true,
    ),
    KitState(
      'Vietnamese, no tap',
      (c) => const ListRow(
        leading: StatusGlyph(status: AgentStatus.done, size: IconSize.lead),
        title: _vi,
        subtitle: 'omp · máy chủ · dự án',
      ),
      bleed: true,
    ),
  ]),
  KitEntry('PressRow', KitStatus.beta, [
    KitState(
      'rest',
      (c) => PressRow(
        onTap: _noop,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text('Open folder', style: Type.cell.copyWith(color: c.ds.text)),
        ),
      ),
      bleed: true,
    ),
    KitState(
      'selected',
      (c) => PressRow(
        onTap: _noop,
        selected: true,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text('Mở thư mục dự án', style: Type.cell.copyWith(color: c.ds.text)),
        ),
      ),
      bleed: true,
    ),
  ]),
  KitEntry('SectionLabel', KitStatus.stable, [
    KitState('plain, with count', (c) => const SectionLabel(label: 'Needs you', count: 2), bleed: true),
    KitState(
      'collapsible, open and closed',
      (c) =>
          _Live<bool>(true, (c, v, set) => SectionLabel(label: 'Done', count: 12, expanded: v, onTap: () => set(!v))),
      bleed: true,
    ),
    KitState(
      'Vietnamese, trailing action',
      (c) => const SectionLabel(
        label: _viShort,
        count: 3,
        trailing: TextAction(label: 'Mark reviewed', onTap: _noop),
      ),
      bleed: true,
    ),
  ]),
  KitEntry('Caret', KitStatus.beta, [
    KitState('closed and open', (c) => const Wrap(spacing: Gap.lg, children: [Caret(open: false), Caret(open: true)])),
  ]),
  KitEntry('EmptyState', KitStatus.beta, [
    KitState(
      'icon, message, action',
      (c) => const EmptyState(
        icon: LucideIcons.bot,
        title: 'No agents running',
        message: 'Start one in herdr and it shows here.',
        action: AppButton(label: 'Add machine', onPressed: _noop),
      ),
    ),
    KitState('inline', (c) => const EmptyState.inline('None started yet.'), bleed: true),
    KitState(
      'inline, Vietnamese',
      (c) => const EmptyState.inline('Chưa có phiên nào được bắt đầu trên máy này.'),
      bleed: true,
    ),
  ]),
  KitEntry('RowList specs', KitStatus.beta, [
    KitState(
      'every spec',
      (c) => _Live<(bool, int)>(
        (true, 1),
        (c, v, set) => RowColumn(
          rows: [
            const HeaderRow(id: 'h', label: 'Terminal', count: 3),
            const ActionRow(
              id: 'a1',
              title: 'Font size',
              icon: LucideIcons.type,
              value: '11.5 pt',
              chevron: true,
              onTap: _noop,
            ),
            const ActionRow(
              id: 'a2',
              title: 'Check for updates',
              icon: LucideIcons.refreshCw,
              kind: RowKind.accent,
              onTap: _noop,
            ),
            const ActionRow(
              id: 'a3',
              title: 'Forget this machine',
              icon: LucideIcons.trash2,
              kind: RowKind.danger,
              subtitle: 'Its key stays on the machine.',
              onTap: _noop,
            ),
            const ActionRow(id: 'a4', title: 'Disabled row', value: 'Off', enabled: false, onTap: _noop),
            ToggleRow(
              id: 't',
              title: 'Wrap lines',
              subtitle: 'Long lines continue below.',
              value: v.$1,
              onChanged: (b) => set((b, v.$2)),
            ),
            const GapRow(id: 'g'),
            CheckRow(id: 'c1', title: 'Light', checked: v.$2 == 1, onTap: () => set((v.$1, 1))),
            CheckRow(id: 'c2', title: 'Dark', checked: v.$2 == 2, onTap: () => set((v.$1, 2))),
            CheckRow(id: 'c3', title: 'Theo hệ thống', subtitle: _vi, checked: v.$2 == 3, onTap: () => set((v.$1, 3))),
            const NoteRow(id: 'n', text: 'The theme changes at once; a cross-fade rebuilt every screen per frame.'),
          ],
        ),
      ),
      bleed: true,
    ),
  ]),

  // Containers.
  KitEntry('Panel', KitStatus.beta, [
    KitState(
      'fill',
      (c) => Panel(
        child: Text(_long, style: Type.compact.copyWith(color: c.ds.text)),
      ),
    ),
    KitState(
      'surface',
      (c) => Panel(
        tone: PanelTone.surface,
        child: Text(_vi, style: Type.compact.copyWith(color: c.ds.text)),
      ),
    ),
  ]),
  KitEntry('FoldPanel', KitStatus.beta, [
    for (final open in const [false, true])
      KitState(
        open ? 'open' : 'closed',
        (c) => _Live<bool>(
          open,
          (c, v, set) => FoldPanel(
            expanded: v,
            onToggle: set,
            header: Text('Plan · 3 of 5 done', style: Type.answer.copyWith(color: c.ds.text)),
            child: Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(
                '1. Read the transport\n2. Reproduce the drop\n3. $_vi',
                style: Type.secondary.copyWith(color: c.ds.textSecondary),
              ),
            ),
          ),
        ),
      ),
  ]),
  KitEntry('StatusStrip', KitStatus.beta, [
    KitState(
      'blocked',
      (c) => StatusStrip(
        color: c.ds.blocked,
        leading: const LinkDot(state: LinkState.attention),
        title: 'Needs attention',
        detail: 'host key changed',
        action: const AppButton(label: 'Open', compact: true, kind: AppButtonKind.secondary, onPressed: _noop),
      ),
    ),
    KitState(
      'danger',
      (c) => StatusStrip(color: c.ds.danger, title: 'Offline', detail: 'Mất kết nối với máy chủ, đang thử lại'),
    ),
    KitState(
      'done',
      (c) => StatusStrip(
        color: c.ds.done,
        leading: const LinkDot(state: LinkState.online),
        title: 'Online',
        onTap: _noop,
      ),
    ),
  ]),
  KitEntry('StatusPanel', KitStatus.beta, [
    KitState(
      'blocked',
      (c) => StatusPanel(
        color: c.ds.blocked,
        icon: LucideIcons.keyRound,
        title: 'Approve the sign-in',
        message: 'Open the link on a computer and enter the code below.',
        trailing: const AppButton(label: 'Open', compact: true, kind: AppButtonKind.secondary, onPressed: _noop),
      ),
    ),
    KitState(
      'danger, mono',
      (c) => StatusPanel(
        color: c.ds.danger,
        icon: LucideIcons.circleAlert,
        title: 'Couldn’t connect',
        message: 'SHA256:9f2b7c1d0e8a4f6b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e',
        mono: true,
      ),
    ),
    KitState(
      'done, Vietnamese',
      (c) => StatusPanel(color: c.ds.done, icon: LucideIcons.check, title: 'Đã kết nối', message: _vi),
    ),
  ]),

  // Answering.
  KitEntry('QuestionWash', KitStatus.beta, [
    KitState(
      'compact, cut: Read all',
      (c) => const QuestionWash(
        question: 'Do you want to run this command? It will apply the pending migrations to the staging database and restart the API.',
        subject: 'make migrate ENV=staging && systemctl restart api && journalctl -u api -n 50',
        onReadAll: _noop,
      ),
    ),
    KitState(
      'full',
      (c) => const QuestionWash(
        question: 'Allow editing src/transport/ssh_transport.dart?',
        subject: '/home/dev/herdr-mobile/app/lib/data/services/ssh_transport.dart',
        size: QuestionWashSize.full,
      ),
    ),
    KitState(
      'Vietnamese',
      (c) => const QuestionWash(question: _vi, subject: 'git push origin feat/kết-nối', size: QuestionWashSize.full),
    ),
  ]),
  KitEntry('AnswerChip', KitStatus.beta, [
    for (final s in AnswerChipState.values)
      KitState(
        s.name,
        (c) => AnswerChip(
          label: 'Yes, and don’t ask again for make migrate',
          state: s,
          error: s == AnswerChipState.failed ? 'The link dropped before the answer went out.' : null,
          onTap: _noop,
        ),
      ),
    KitState(
      'risk: gate (held)',
      (c) => const AnswerChip(
        label: 'Yes, push to origin',
        risk: AnswerRisk.gate,
        hold: true,
        reason: 'pushes to a remote',
        onTap: _noop,
        onHeld: _noop,
      ),
    ),
    KitState(
      'risk: gate, primed',
      (c) => const AnswerChip(
        label: 'Yes, push to origin',
        risk: AnswerRisk.gate,
        hold: true,
        reason: 'pushes to a remote',
        state: AnswerChipState.primed,
        onTap: _noop,
        onHeld: _noop,
      ),
    ),
    KitState(
      'risk: elevated',
      (c) => const AnswerChip(label: 'Allow all edits this session', risk: AnswerRisk.elevated, onTap: _noop),
    ),
    KitState(
      'danger tone, narrow',
      (c) => const Align(
        alignment: AlignmentDirectional.centerEnd,
        child: AnswerChip(label: 'Stop', tone: AnswerChipTone.danger, wide: false, onTap: _noop),
      ),
    ),
    KitState('Vietnamese, with detail', (c) => const AnswerChip(label: _vi, detail: 'Chỉ cho phiên này', onTap: _noop)),
  ]),
  KitEntry('HoldToConfirm', KitStatus.beta, [KitState('hold to stop', (c) => const _HoldDemo())]),

  // Bars and pages.
  KitEntry('AppTopBar', KitStatus.beta, [
    KitState('title', (c) => AppTopBar(title: 'Session'), bleed: true),
    KitState(
      'subtitle and glyph',
      (c) => AppTopBar(
        title: 'Fix flaky retry test',
        subtitle: 'Claude Code · build-box · herdr-mobile',
        glyph: StatusGlyph(status: AgentStatus.blocked, size: IconSize.row),
      ),
      bleed: true,
    ),
    KitState(
      'two actions, Vietnamese',
      (c) => AppTopBar(
        title: _vi,
        subtitle: 'omp · máy chủ',
        glyph: StatusGlyph(status: AgentStatus.working, size: IconSize.row),
        actions: [
          CircleButton(icon: HerdrIcons.folder, tooltip: 'Files', onPressed: _noop),
          CircleButton(icon: LucideIcons.ellipsis, tooltip: 'More', onPressed: _noop),
        ],
      ),
      bleed: true,
    ),
    KitState(
      'overlay on a photo',
      (c) => DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(colors: [c.ds.accent, c.ds.working])),
        child: AppTopBar(
          title: '3 of 12',
          subtitle: 'IMG_20260520_093012.jpg',
          overlay: true,
          actions: [CircleButton(icon: LucideIcons.ellipsis, tooltip: 'More', onPressed: _noop)],
        ),
      ),
      bleed: true,
    ),
  ]),
  KitEntry('SliverLargeTitle', KitStatus.beta, [
    KitState('root page', (c) => const _LargeTitleDemo(back: false), bleed: true),
    KitState('pushed, subtitle, chips', (c) => const _LargeTitleDemo(back: true), bleed: true),
  ]),
  KitEntry('SheetScaffold', KitStatus.beta, [
    KitState(
      'actions',
      (c) => const _SheetDemo(
        SheetScaffold(
          title: 'Pane options',
          kind: SheetKind.actions,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetActionRow(
                action: SheetAction(label: 'Copy pane id', icon: LucideIcons.copy, onTap: _noop),
                onTap: _noop,
              ),
              SheetActionRow(
                action: SheetAction(label: 'Rename', icon: LucideIcons.squarePen, onTap: _noop),
                onTap: _noop,
              ),
              SheetActionRow(
                action: SheetAction(label: 'Close pane', icon: LucideIcons.trash2, destructive: true, onTap: _noop),
                onTap: _noop,
              ),
              SheetActionRow(
                action: SheetAction(
                  label: 'Open files',
                  icon: HerdrIcons.folder,
                  unavailable: 'The machine is offline.',
                  onTap: _noop,
                ),
                onTap: _noop,
              ),
            ],
          ),
        ),
      ),
      bleed: true,
    ),
    KitState(
      'list',
      (c) => _SheetDemo(
        SheetScaffold(
          title: 'Background work',
          kind: SheetKind.list,
          bleed: true,
          child: RowColumn(
            rows: [
              for (var i = 1; i <= 4; i++)
                EntityRow(
                  id: 'job$i',
                  title: i == 4 ? _vi : 'cargo test --workspace #$i',
                  subtitle: 'job · 4m',
                  leading: const StatusGlyph(status: AgentStatus.working, size: IconSize.lead),
                ),
            ],
          ),
        ),
      ),
      bleed: true,
    ),
    KitState(
      'message',
      (c) => _SheetDemo(
        SheetScaffold(
          title: 'Forget build-box?',
          kind: SheetKind.message,
          actions: const [
            AppButton(label: 'Forget machine', kind: AppButtonKind.danger, expand: true, onPressed: _noop),
            AppButton(label: 'Cancel', kind: AppButtonKind.ghost, expand: true, onPressed: _noop),
          ],
          child: Text(
            'Its saved key and history leave this phone. The machine keeps its sessions.',
            style: Type.compact.copyWith(color: c.ds.textSecondary),
          ),
        ),
      ),
      bleed: true,
    ),
    KitState(
      'form',
      (c) => const _SheetDemo(
        SheetScaffold(
          title: 'Rename session',
          kind: SheetKind.form,
          actions: [AppButton(label: 'Save', expand: true, onPressed: _noop)],
          child: LabeledField(label: 'Name', hint: 'Fix flaky retry test'),
        ),
      ),
      bleed: true,
    ),
  ]),
  KitEntry('FloatingPill', KitStatus.beta, [
    KitState(
      'regular',
      (c) => const Center(
        child: FloatingPill(
          leading: StatusGlyph(status: AgentStatus.blocked, size: IconSize.row),
          label: '2 need you',
          detail: '1 to review',
          onTap: _noop,
        ),
      ),
    ),
    KitState(
      'compact',
      (c) => const Center(
        child: FloatingPill(
          icon: LucideIcons.arrowDown,
          label: 'Jump to latest',
          size: FloatingPillSize.compact,
          onTap: _noop,
        ),
      ),
    ),
    KitState(
      'icon only',
      (c) => const Center(
        child: FloatingPill(
          icon: LucideIcons.arrowDown,
          semanticLabel: 'Jump to latest',
          size: FloatingPillSize.compact,
          onTap: _noop,
        ),
      ),
    ),
  ]),
  KitEntry('Toast', KitStatus.beta, [
    // Text clamped at kBarTextScale, as the live toast is.
    KitState('info', (c) => _bar(const ToastCard(message: 'Path copied'))),
    KitState('success', (c) => _bar(const ToastCard(message: 'Marked 3 reviewed', kind: ToastKind.success))),
    KitState(
      'failed',
      (c) => _bar(const ToastCard(message: 'Couldn’t copy: the clipboard refused it.', kind: ToastKind.failed)),
    ),
    KitState(
      'with action',
      (c) => _bar(const ToastCard(message: 'Marked 3 reviewed', actionLabel: 'Undo', onAction: _noop)),
    ),
    KitState(
      'long, Vietnamese, action',
      (c) => _bar(const ToastCard(message: _vi, kind: ToastKind.failed, actionLabel: 'Retry', onAction: _noop)),
    ),
    KitState(
      'live: show one',
      (c) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: AppButton(
          label: 'Show a toast',
          kind: AppButtonKind.secondary,
          compact: true,
          onPressed: () => showToast(c, 'Marked 3 reviewed', action: const ToastAction('Undo', _noop)),
        ),
      ),
    ),
  ]),

  // Waiting and rare moments.
  KitEntry('BusySpinner', KitStatus.beta, [
    KitState(
      'default and large',
      (c) => Wrap(
        spacing: Gap.lg,
        children: [
          const BusySpinner(),
          BusySpinner(size: IconSize.lead, color: c.ds.accent),
        ],
      ),
    ),
  ]),
  KitEntry('ProgressLine', KitStatus.beta, [
    KitState(
      'empty, half, full',
      (c) => const Column(
        spacing: Gap.md,
        children: [ProgressLine(fraction: 0), ProgressLine(fraction: 0.5), ProgressLine(fraction: 1)],
      ),
    ),
  ]),
  KitEntry('LoadingRow', KitStatus.beta, [
    KitState('row', (c) => const LoadingRow('Loading sessions…'), bleed: true),
    KitState(
      'centred, Vietnamese',
      (c) => const LoadingRow('Đang tải danh sách phiên làm việc từ máy chủ…', center: true),
      bleed: true,
    ),
  ]),
  KitEntry('Skeleton', KitStatus.beta, [
    KitState('lines', (c) => const SizedBox(height: _demoHeight, child: Skeleton()), bleed: true),
    KitState('rows', (c) => const SizedBox(height: _demoHeight, child: Skeleton(rows: true)), bleed: true),
  ]),
  KitEntry('DrawCheck', KitStatus.beta, [
    KitState('tap to draw again', (c) => _Replay((c) => DrawCheck(color: c.ds.done, size: IconSize.empty))),
    KitState('still', (c) => DrawCheck(color: c.ds.done, size: IconSize.lead, animate: false)),
  ]),
  KitEntry('BrandMark', KitStatus.beta, [
    KitState('tap to draw again', (c) => _Replay((c) => const BrandMark())),
    KitState('still', (c) => const BrandMark(animate: false)),
  ]),
];

/// Height of a demo box for a component that fills what it is given (a
/// skeleton is a lazy list).
const _demoHeight = 200.0;

/// Chrome text stops growing at [kBarTextScale]: a part shown out of its bar
/// gets the same clamp the bar gives it.
Widget _bar(Widget child) => MediaQuery.withClampedTextScaling(maxScaleFactor: kBarTextScale, child: child);

const _typeRoles = <(String, TextStyle)>[
  ('largeTitle', Type.largeTitle),
  ('title', Type.title),
  ('h1', Type.h1),
  ('h2', Type.h2),
  ('h3', Type.h3),
  ('barTitle', Type.barTitle),
  ('row', Type.row),
  ('cell', Type.cell),
  ('input', Type.input),
  ('body', Type.body),
  ('bodyStrong', Type.bodyStrong),
  ('compact', Type.compact),
  ('prompt', Type.prompt),
  ('answer', Type.answer),
  ('button', Type.button),
  ('buttonCompact', Type.buttonCompact),
  ('secondary', Type.secondary),
  ('secondaryStrong', Type.secondaryStrong),
  ('label', Type.label),
  ('labelStrong', Type.labelStrong),
  ('caption', Type.caption),
  ('captionStrong', Type.captionStrong),
  ('count', Type.count),
  ('badge', Type.badge),
];

const _monoRoles = <(String, TextStyle)>[
  ('Mono.small', Mono.small),
  ('Mono.base', Mono.base),
  ('Mono.input', Mono.input),
  ('Mono.preview', Mono.preview),
];

/// A type role: its numbers, then a line of English and one of Vietnamese.
class _TypeSample extends StatelessWidget {
  const _TypeSample({required this.name, required this.style});

  final String name;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final s = style;
    final spec =
        '${s.fontSize} / ${s.height} / w${s.fontWeight?.value ?? 400}'
        '${s.letterSpacing == null || s.letterSpacing == 0 ? '' : ' / ${s.letterSpacing}'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(spec, style: Mono.small.copyWith(color: ds.textMuted)),
        const SizedBox(height: Gap.xs),
        Text('Fix flaky test 4m 0129', style: s.copyWith(color: ds.text)),
        Text('Cần bạn xử lý · Đã xong', style: s.copyWith(color: ds.text)),
      ],
    );
  }
}

/// WCAG contrast of [fg] (composited over [bg] when translucent) against [bg].
double _contrast(Color fg, Color bg) {
  final a = Color.alphaBlend(fg, bg).computeLuminance();
  final b = bg.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// Every colour role and getter, its value, and its contrast against `bg`
/// (and against the inverse surface for the colours drawn on it).
class _ColourSheet extends StatelessWidget {
  const _ColourSheet();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final roles = <(String, Color, (String, Color)?)>[
      ('bg', ds.bg, null),
      ('surface', ds.surface, null),
      ('fill', ds.fill, null),
      ('fillPressed', ds.fillPressed, null),
      ('hairline', ds.hairline, null),
      ('border', ds.border, null),
      ('text', ds.text, null),
      ('textSecondary', ds.textSecondary, null),
      ('textMuted', ds.textMuted, null),
      ('textTertiary', ds.textTertiary, null),
      ('accent', ds.accent, null),
      ('accentText', ds.accentText, null),
      ('onAccent', ds.onAccent, ('accent', ds.accent)),
      ('accentPressed', ds.accentPressed, null),
      ('accentWash', ds.accentWash, null),
      ('accentWashPressed', ds.accentWashPressed, null),
      ('blocked', ds.blocked, null),
      ('working', ds.working, null),
      ('done', ds.done, null),
      ('danger', ds.danger, null),
      ('blockedText', ds.blockedText, null),
      ('dangerText', ds.dangerText, null),
      ('onStatus', ds.onStatus, ('blocked', ds.blocked)),
      ('blockedWash', ds.blockedWash, null),
      ('wash(danger)', ds.wash(ds.danger), null),
      ('washPressed(danger)', ds.washPressed(ds.danger), null),
      ('armedEdge(danger)', ds.armedEdge(ds.danger), null),
      ('pressTint', ds.pressTint, null),
      ('inverseSurface', ds.inverseSurface, null),
      ('onInverse', ds.onInverse, ('inverseSurface', ds.inverseSurface)),
      ('inverseAccent', ds.inverseAccent, ('inverseSurface', ds.inverseSurface)),
      ('faint', ds.faint, null),
      ('skeleton', ds.skeleton, null),
      ('selection', ds.selection, null),
      ('linkUnderline', ds.linkUnderline, null),
      ('scrim', ds.scrim, null),
      ('photoScrim', ds.photoScrim, null),
      ('onPhoto', ds.onPhoto, ('photoScrim', ds.photoScrim)),
      ('addedText', ds.addedText, null),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (name, color, on) in roles)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: Gap.xs),
            child: Row(
              children: [
                Container(
                  width: Gap.xl,
                  height: Gap.xl,
                  decoration: BoxDecoration(
                    color: on == null ? color : Color.alphaBlend(color, on.$2),
                    borderRadius: BorderRadius.circular(Radii.xs),
                    border: Border.all(color: ds.hairline),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: Type.labelStrong.copyWith(color: ds.text)),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${_hex(color)} · ',
                              style: Mono.small.copyWith(color: ds.textMuted),
                            ),
                            TextSpan(
                              text: '${_contrast(color, ds.bg).toStringAsFixed(2)}:1 on bg',
                              style: Type.count.copyWith(color: ds.text),
                            ),
                            if (on != null)
                              TextSpan(
                                text: ' · ${_contrast(color, on.$2).toStringAsFixed(2)}:1 on ${on.$1}',
                                style: Type.count.copyWith(color: ds.text),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RadiusSheet extends StatelessWidget {
  const _RadiusSheet();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Wrap(
      spacing: Gap.md,
      runSpacing: Gap.md,
      children: [
        for (final (name, r) in const [
          ('xs', Radii.xs),
          ('sm', Radii.sm),
          ('md', Radii.md),
          ('lg', Radii.lg),
          ('pill', Radii.pill),
        ])
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: Gap.xxl + Gap.xl,
                height: Gap.xxl + Gap.xl,
                decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(r)),
              ),
              const SizedBox(height: Gap.xs),
              Text('$name ${r == Radii.pill ? '' : r.round()}', style: Type.caption.copyWith(color: ds.textMuted)),
            ],
          ),
      ],
    );
  }
}

class _IconSheet extends StatelessWidget {
  const _IconSheet();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Wrap(
      spacing: Gap.lg,
      runSpacing: Gap.md,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        for (final (name, s) in const [
          ('inline', IconSize.inline),
          ('row', IconSize.row),
          ('bar', IconSize.bar),
          ('lead', IconSize.lead),
          ('nav', IconSize.nav),
          ('empty', IconSize.empty),
          ('hero', IconSize.hero),
        ])
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(HerdrIcons.agents, size: s, color: ds.textSecondary),
              const SizedBox(height: Gap.xs),
              Text('$name ${s.round()}', style: Type.caption.copyWith(color: ds.textMuted)),
            ],
          ),
      ],
    );
  }
}

/// herdr's drawn glyphs, each with its name: peers in a bar weigh the same.
class _HerdrIconSheet extends StatelessWidget {
  const _HerdrIconSheet({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Wrap(
      spacing: Gap.lg,
      runSpacing: Gap.md,
      children: [
        for (final (name, icon) in const [
          ('agents', HerdrIcons.agents),
          ('machines', HerdrIcons.machines),
          ('machinesOff', HerdrIcons.machinesOff),
          ('settings', HerdrIcons.settings),
          ('stop', HerdrIcons.stop),
          ('stopMark', HerdrIcons.stopMark),
          ('message', HerdrIcons.message),
          ('close', HerdrIcons.close),
          ('folder', HerdrIcons.folder),
        ])
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: size, color: ds.text),
              const SizedBox(height: Gap.xs),
              Text(name, style: Type.caption.copyWith(color: ds.textMuted)),
            ],
          ),
      ],
    );
  }
}

class _GapSheet extends StatelessWidget {
  const _GapSheet();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (name, g) in const [
          ('hair', Gap.hair),
          ('xs', Gap.xs),
          ('sm', Gap.sm),
          ('md', Gap.md),
          ('lg', Gap.lg),
          ('xl', Gap.xl),
          ('xxl', Gap.xxl),
          ('gutter', Gap.gutter),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(
              children: [
                SizedBox(
                  width: Gap.xxl + Gap.xxl,
                  child: Text('$name ${g.round()}', style: Type.caption.copyWith(color: ds.textMuted)),
                ),
                Container(width: g, height: Gap.md, color: ds.accent),
              ],
            ),
          ),
      ],
    );
  }
}

/// A button per duration token; each tap moves a dot [Motion.travel] and
/// back with that duration and [Motion.easeOut]. Reduced motion jumps.
class _MotionSheet extends StatelessWidget {
  const _MotionSheet();

  static const _tokens = <(String, Duration)>[
    ('press', Motion.press),
    ('release', Motion.release),
    ('fade', Motion.fade),
    ('standard', Motion.standard),
    ('expand', Motion.expand),
    ('settle', Motion.settle),
    ('sheetIn', Motion.sheetIn),
    ('sheetOut', Motion.sheetOut),
    ('page', Motion.page),
    ('draw', Motion.draw),
    ('brand', Motion.brand),
    ('holdFill', Motion.holdFill),
    ('holdSnapBack', Motion.holdSnapBack),
  ];

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (name, d) in _tokens) _MotionRow(name: name, duration: d),
        const SizedBox(height: Gap.md),
        Text(
          'PressScale: panel ${PressScale.panel}, button ${PressScale.button}, chip ${PressScale.chip}, icon ${PressScale.icon}. '
          'Travel ${Motion.travel.round()} dp, enter scale ${Motion.enterScale}, roll ${Motion.rollTravel} of the font size.',
          style: Type.secondary.copyWith(color: ds.textSecondary),
        ),
      ],
    );
  }
}

class _MotionRow extends StatefulWidget {
  const _MotionRow({required this.name, required this.duration});

  final String name;
  final Duration duration;

  @override
  State<_MotionRow> createState() => _MotionRowState();
}

class _MotionRowState extends State<_MotionRow> {
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Row(
      children: [
        Expanded(
          child: AppButton(
            label: '${widget.name} ${widget.duration.inMilliseconds} ms',
            kind: AppButtonKind.secondary,
            compact: true,
            onPressed: () => setState(() => _moved = !_moved),
          ),
        ),
        const SizedBox(width: Gap.md),
        SizedBox(
          width: Motion.travel + Gap.md,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: _moved ? Motion.travel : 0),
            duration: Motion.of(context, widget.duration),
            curve: Motion.easeOut,
            builder: (context, x, child) => Transform.translate(offset: Offset(x, 0), child: child),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                width: Gap.md,
                height: Gap.md,
                decoration: BoxDecoration(color: ds.accent, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A [HoldToConfirm] drawn as a wide chip: the fill runs while held, a tap
/// says how to send, a full hold says it went.
class _HoldDemo extends StatefulWidget {
  const _HoldDemo();

  @override
  State<_HoldDemo> createState() => _HoldDemoState();
}

class _HoldDemoState extends State<_HoldDemo> {
  int _sent = 0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return HoldToConfirm(
      onConfirmed: () => setState(() => _sent++),
      onActivate: () => setState(() => _sent++),
      builder: (context, hold) => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTap),
          child: ColoredBox(
            color: ds.fill,
            child: Stack(
              alignment: Alignment.center,
              children: [
                hold.fill,
                Text(
                  hold.showsHold ? 'Hold to stop · 3 jobs' : (_sent == 0 ? 'Stop all jobs' : 'Stopped ×$_sent'),
                  style: Type.answer.copyWith(color: ds.dangerText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A [SliverLargeTitle] over two rows, in a list that does not scroll.
class _LargeTitleDemo extends StatelessWidget {
  const _LargeTitleDemo({required this.back});

  final bool back;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final actions = [const CircleButton(icon: LucideIcons.plus, tooltip: 'Add machine', onPressed: _noop)];
    return ColoredBox(
      color: ds.bg,
      child: CustomScrollView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        slivers: [
          if (back)
            SliverLargeTitle.back(
              title: 'build-box',
              subtitle: Text(
                '3 agents · dev@build.example.com',
                style: Type.secondary.copyWith(color: ds.textSecondary),
              ),
              actions: actions,
              bottomHeight: AppChip.height,
              // The header insets its bottom to the page gutter itself.
              bottom: const Row(
                children: [
                  AppChip(label: 'All', selected: true, onTap: _noop),
                  SizedBox(width: Gap.sm),
                  AppChip(label: 'Needs you', count: 2, onTap: _noop),
                ],
              ),
            )
          else
            SliverLargeTitle(title: 'Machines', actions: actions),
          SliverToBoxAdapter(
            child: ListRow(
              leading: const LinkDot(state: LinkState.online),
              title: 'build-box',
              subtitle: '3 agents · dev@build.example.com',
              onTap: _noop,
            ),
          ),
        ],
      ),
    );
  }
}

/// A sheet body drawn in place: the sheet's surface, top corners and grabber
/// around a [SheetScaffold], as [showAppSheet] would show it.
class _SheetDemo extends StatelessWidget {
  const _SheetDemo(this.scaffold);

  final SheetScaffold scaffold;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.lg)),
        border: Border(top: BorderSide(color: ds.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: Gap.sm),
            child: Center(child: SheetGrabber()),
          ),
          scaffold,
        ],
      ),
    );
  }
}

/// Holds one value for a demo that changes it.
class _Live<T> extends StatefulWidget {
  const _Live(this.initial, this.builder);

  final T initial;
  final Widget Function(BuildContext context, T value, ValueChanged<T> set) builder;

  @override
  State<_Live<T>> createState() => _LiveState<T>();
}

class _LiveState<T> extends State<_Live<T>> {
  late T _value = widget.initial;

  @override
  Widget build(BuildContext context) => widget.builder(context, _value, (v) => setState(() => _value = v));
}

/// Rebuilds [builder]'s widget from scratch on a tap, so a one-shot drawing
/// plays again.
class _Replay extends StatefulWidget {
  const _Replay(this.builder);

  final WidgetBuilder builder;

  @override
  State<_Replay> createState() => _ReplayState();
}

class _ReplayState extends State<_Replay> {
  int _run = 0;

  @override
  Widget build(BuildContext context) => PressBuilder(
    onTap: () => setState(() => _run++),
    haptic: true,
    semanticLabel: 'Draw again',
    builder: (context, pressed) => Align(
      alignment: AlignmentDirectional.centerStart,
      child: KeyedSubtree(key: ValueKey(_run), child: widget.builder(context)),
    ),
  );
}
