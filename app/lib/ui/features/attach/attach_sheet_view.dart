import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/repositories/agent_session.dart';
import '../../core/motion.dart';
import 'attach_bars.dart';
import 'attach_kit.dart';
import 'files_tab.dart';
import 'gallery_tab.dart';
import 'host_tab.dart';
import 'tray.dart';

/// How the sheet was left, besides picking things.
enum AttachOutcome {
  /// Attach was tapped: the tray's picks go to the message.
  attached,

  /// The Camera tile: close, then open the camera app.
  camera,

  /// The fallback: close, then open the system photo picker.
  systemPicker,
}

/// The state one opening of the sheet shares between its body and its bars:
/// the tray (every tab's picks), the tab on show.
class AttachSheetController {
  AttachSheetController({
    required this.kit,
    required this.session,
    required this.tray,
    required this.onProblem,
    required this.finish,
  }) : tab = ValueNotifier<AttachTab>(kit.tab);

  final AttachKit kit;
  final AgentSessionView session;
  final AttachTray tray;
  final void Function(String message) onProblem;

  /// Closes the sheet with [outcome].
  final void Function(AttachOutcome outcome) finish;

  final ValueNotifier<AttachTab> tab;

  void select(AttachTab next) {
    if (tab.value == next) return;
    kit.tab = next;
    tab.value = next;
  }

  void dispose() => tab.dispose();

  /// The sheet's body: the tabs, cross-fading, each kept alive once shown.
  Widget buildBody(BuildContext context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    label: 'Attach',
    explicitChildNodes: true,
    child: _Tabs(
      tab: tab,
      build: (t) => switch (t) {
        AttachTab.gallery => GalleryTab(
          kit: kit,
          session: session,
          tray: tray,
          onCamera: () => finish(AttachOutcome.camera),
          onSystemPicker: () => finish(AttachOutcome.systemPicker),
        ),
        AttachTab.files => FilesTab(kit: kit, session: session, tray: tray, onProblem: onProblem),
        AttachTab.host => HostTab(session: session, tray: tray, onProblem: onProblem),
      },
    ),
  );

  /// The action bar and the tab bar, pinned to the bottom edge.
  Widget buildBars(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AttachActionBar(tray: tray, onAttach: () => finish(AttachOutcome.attached)),
          // The keyboard has the room while a field is being typed in.
          if (keyboard)
            const SizedBox(height: AttachTabBar.margin)
          else
            Padding(
              padding: EdgeInsets.only(bottom: bottom + AttachTabBar.margin),
              child: ValueListenableBuilder<AttachTab>(
                valueListenable: tab,
                builder: (context, t, _) => AttachTabBar(selected: t, onChanged: select),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows the tab that is selected and keeps the others (once opened) alive
/// but out of layout, so coming back is instant and the scroll position is
/// where it was. A switch cross-fades over `Motion.fade`; at rest nothing is
/// wrapped in an opacity layer.
class _Tabs extends StatefulWidget {
  const _Tabs({required this.tab, required this.build});

  final ValueNotifier<AttachTab> tab;
  final Widget Function(AttachTab tab) build;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this, duration: Motion.fade, value: 1);
  final _keys = {for (final t in AttachTab.values) t: GlobalKey()};
  final _built = <AttachTab>{};
  late AttachTab _current = widget.tab.value;
  AttachTab? _leaving;

  @override
  void initState() {
    super.initState();
    _built.add(_current);
    widget.tab.addListener(_onTab);
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.completed && _leaving != null && mounted) setState(() => _leaving = null);
    });
  }

  void _onTab() {
    final next = widget.tab.value;
    if (next == _current) return;
    setState(() {
      _leaving = _current;
      _current = next;
      _built.add(next);
    });
    if (Motion.reduced(context)) {
      _fade.value = 1;
      _leaving = null;
    } else {
      unawaited(_fade.forward(from: 0).catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    widget.tab.removeListener(_onTab);
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fading = _leaving != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final t in AttachTab.values)
          if (_built.contains(t))
            Offstage(
              key: ValueKey(t),
              offstage: t != _current && t != _leaving,
              child: _wrap(t, fading, KeyedSubtree(key: _keys[t], child: widget.build(t))),
            ),
      ],
    );
  }

  Widget _wrap(AttachTab t, bool fading, Widget child) {
    if (!fading) return child;
    if (t == _current) return FadeTransition(opacity: _fade, child: child);
    if (t == _leaving) return IgnorePointer(child: FadeTransition(opacity: ReverseAnimation(_fade), child: child));
    return child;
  }
}
