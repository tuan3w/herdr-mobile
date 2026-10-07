import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/services/dictation.dart';
import '../../core/motion.dart';

/// One message box's dictation: what is heard goes into the box as it is heard,
/// at the cursor, and nothing is ever sent (the person reads it and presses
/// send, as with a quick-phrase chip). The words stay in the box when the
/// listen ends, by tap or by a pause, and the box keeps the text around them.
///
/// [Dictation] listens for the whole app, so [listening] is true only for the
/// box that started it: a second composer never shows a mic that is not its own.
class DictationSession extends ChangeNotifier {
  DictationSession({required this.dictation, required this.input, required this.focus, required this.onProblem}) {
    dictation.addListener(_changed);
  }

  final Dictation dictation;
  final TextEditingController input;

  /// The box's focus node: how the box is found to scroll to what was just heard.
  final FocusNode focus;

  /// Tells the person why a listen did not start or ended badly.
  final void Function(DictationProblem problem) onProblem;

  bool _mine = false;
  String _head = '';
  String _tail = '';

  bool get listening => _mine && dictation.listening;

  void _changed() {
    if (_mine && !dictation.listening) _mine = false;
    notifyListeners();
  }

  /// Starts listening into the box, or ends the listen that is running.
  Future<void> toggle() async {
    if (listening) {
      await dictation.stop();
      return;
    }
    if (dictation.listening) return;
    Haptics.tick();
    final value = input.value;
    final at = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    _head = value.text.substring(0, at.start);
    _tail = value.text.substring(at.end);
    _mine = true;
    notifyListeners();
    final started = await dictation.start(
      onWords: _heard,
      onProblem: (problem) {
        _mine = false;
        notifyListeners();
        onProblem(problem);
      },
    );
    if (!started) {
      _mine = false;
      notifyListeners();
    }
  }

  void _heard(String words, bool isFinal) {
    if (!_mine || words.isEmpty) return;
    final before = _head.isEmpty || RegExp(r'\s$').hasMatch(_head) ? _head : '$_head ';
    final after = _tail.isEmpty || _tail.startsWith(RegExp(r'\s')) ? _tail : ' $_tail';
    input.value = TextEditingValue(
      text: '$before$words$after',
      selection: TextSelection.collapsed(offset: before.length + words.length),
    );
    // The box scrolls to the caret only for what the person types: without
    // this a long dictation runs on out of sight below the fifth line.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final field = focus.context?.findAncestorStateOfType<EditableTextState>();
      if (field != null && input.selection.isValid) field.bringIntoView(input.selection.extent);
    });
  }

  @override
  void dispose() {
    dictation.removeListener(_changed);
    if (_mine) unawaited(dictation.cancel());
    super.dispose();
  }
}
