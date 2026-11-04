import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'kit_catalog.dart';

/// The hidden Kit screen: every token sheet and kit component of
/// [kitCatalog], each opening a page of its states. Reached only by holding
/// `Version …` in Settings, in every build.
class KitScreen extends StatelessWidget {
  const KitScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tokens = kitCatalog.where((e) => e.tokens).toList();
    final components = kitCatalog.where((e) => !e.tokens).toList();
    ActionRow row(KitEntry e) => ActionRow(
      id: e.slug,
      title: e.name,
      value: e.status.name,
      chevron: true,
      onTap: () =>
          unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KitEntryPage(entry: e)))),
    );
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          AppTopBar(
            title: context.l10n.uiKit,
            subtitle: countOf(kitCatalog.length, context.l10n.uiEntry, context.l10n.uiEntries),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                RowList(
                  rows: [
                    HeaderRow(id: 'tokens', label: context.l10n.uiTokens, count: tokens.length),
                    for (final e in tokens) row(e),
                    const GapRow(id: 'gap'),
                    HeaderRow(id: 'components', label: context.l10n.uiComponents, count: components.length),
                    for (final e in components) row(e),
                  ],
                ),
                SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + Gap.xl)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One entry's states, each under its [SectionLabel], in the theme and text
/// scale chosen at the top (the page's own bar keeps the app's).
class KitEntryPage extends StatefulWidget {
  const KitEntryPage({super.key, required this.entry, this.dark, this.scale = 1});

  final KitEntry entry;

  /// The theme the states start in; null follows the app's.
  final bool? dark;

  /// The text scale the states start at.
  final double scale;

  /// The text scales offered.
  static const scales = [1.0, 1.6];

  /// The states' scroll view, and its content: a render that shows the whole
  /// entry grows the screen by the difference.
  static const scrollKey = ValueKey('kit.scroll');
  static const bodyKey = ValueKey('kit.body');

  @override
  State<KitEntryPage> createState() => _KitEntryPageState();
}

class _KitEntryPageState extends State<KitEntryPage> {
  late bool? _dark = widget.dark;
  late double _scale = widget.scale;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final dark = _dark ?? Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final entry = widget.entry;
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTopBar(title: entry.name, subtitle: entry.status.name),
          Padding(
            padding: const EdgeInsets.only(left: Gap.gutter, right: Gap.gutter, bottom: Gap.sm),
            child: Row(
              children: [
                Expanded(
                  child: Segmented<bool>(
                    value: dark,
                    onChanged: (v) => setState(() => _dark = v),
                    options: const [SegmentOption(false, 'Light'), SegmentOption(true, 'Dark')],
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Segmented<double>(
                    value: _scale,
                    onChanged: (v) => setState(() => _scale = v),
                    options: [for (final s in KitEntryPage.scales) SegmentOption(s, '${s}x')],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Theme(
              data: dark ? AppTheme.dark() : AppTheme.light(),
              child: MediaQuery(
                // The states sit under this page's bar: the status bar and
                // gesture insets are not theirs to clear.
                data: media.copyWith(
                  textScaler: TextScaler.linear(_scale),
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                ),
                child: Builder(
                  builder: (context) => ColoredBox(
                    color: context.ds.bg,
                    child: SingleChildScrollView(
                      key: KitEntryPage.scrollKey,
                      child: Padding(
                        key: KitEntryPage.bodyKey,
                        padding: EdgeInsets.only(bottom: media.padding.bottom + Gap.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final state in entry.states) ...[
                              SectionLabel(label: state.label),
                              Padding(
                                padding: state.bleed
                                    ? EdgeInsets.zero
                                    : const EdgeInsets.symmetric(horizontal: Gap.gutter),
                                child: Builder(builder: state.build),
                              ),
                              const SizedBox(height: Gap.md),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
