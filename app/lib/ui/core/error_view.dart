import 'package:flutter/material.dart';

import 'tokens.dart';

/// Flutter's release-mode answer to a widget that throws while building is a
/// gray box that takes all the room it is offered: in a list that is the whole
/// screen of a transcript, with nothing said. This is one quiet row that says
/// what happened and where to look, and stays as tall as a row.
///
/// Installed once, by [installErrorReporting]; the failed widget's place in the
/// tree gives it the theme.
Widget compactErrorView(FlutterErrorDetails details) => Builder(
  builder: (context) {
    final ds = Theme.of(context).extension<Ds>();
    final message = details.exceptionAsString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, maxHeight: 96),
        margin: const EdgeInsets.symmetric(vertical: Gap.xs),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: ds?.fill ?? const Color(0xFFEFEFEF),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Couldn’t draw this · $message',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: (ds == null ? const TextStyle(fontSize: 13) : Type.secondary).copyWith(
            color: ds?.dangerText ?? const Color(0xFF8A1C1C),
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  },
);

/// What was reported already: a failing row reports on every rebuild, and the
/// log should say each failure once.
final _reported = <String>{};

/// Sends every distinct failure, with the top of its stack, to the log
/// (`adb logcat -s flutter`). Flutter's own release-mode report prints the first
/// error in full and every later one as "Another exception was thrown:
/// Instance of DiagnosticsProperty", which names nothing.
void reportFlutterError(FlutterErrorDetails details) {
  FlutterError.presentError(details);
  final stack = details.stack?.toString().split('\n').take(14).join('\n') ?? '';
  final text = '${details.exceptionAsString()}\n$stack';
  if (_reported.length < 200 && _reported.add(text)) {
    debugPrint('herdr: ${details.library ?? 'flutter'}: $text');
  }
}

/// Replaces the gray box of a widget that failed to build, and makes the log
/// say what failed.
void installErrorReporting() {
  ErrorWidget.builder = compactErrorView;
  FlutterError.onError = reportFlutterError;
}
