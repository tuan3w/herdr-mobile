import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'press.dart';
import 'theme.dart';

/// The one search field: 44 high, a search glyph, and a clear button once
/// there is something to clear. A tap anywhere else puts the keyboard away.
/// Autocorrect is off (names, paths and ids are not words).
///
/// [hint] names the place searched (`Find in src`, `Search sessions`) and is
/// what a screen reader announces for the field.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    this.controller,
    required this.hint,
    this.focusNode,
    this.onChanged,
    this.onPointerDown,
  });

  /// Owned by the caller when given (to clear it from outside); else the
  /// field keeps its own.
  final TextEditingController? controller;
  final String hint;
  final FocusNode? focusNode;

  /// Every edit, and `''` when the clear button empties the field.
  final ValueChanged<String>? onChanged;

  /// A finger landed on the field (before focus): a sheet that grows to give
  /// the keyboard room.
  final VoidCallback? onPointerDown;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  TextEditingController? _own;

  TextEditingController get _controller => widget.controller ?? (_own ??= TextEditingController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final controller = _controller;
    final field = ListenableBuilder(
      listenable: controller,
      builder: (context, _) => TextField(
        controller: controller,
        focusNode: widget.focusNode,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.search,
        onChanged: widget.onChanged,
        onTapOutside: (_) => (widget.focusNode ?? FocusManager.instance.primaryFocus)?.unfocus(),
        style: Type.input.copyWith(color: ds.text),
        cursorColor: ds.accent,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: widget.hint,
          constraints: const BoxConstraints(minHeight: kMinTap, maxHeight: kMinTap),
          contentPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
          prefixIcon: Icon(LucideIcons.search, size: IconSize.row, color: ds.textTertiary),
          suffixIcon: controller.text.isEmpty
              ? null
              : PressBuilder(
                  onTap: _clear,
                  semanticLabel: context.l10n.uiClearSearch,
                  minTapSize: kMinTap,
                  builder: (context, pressed) =>
                      Icon(LucideIcons.x, size: IconSize.row, color: pressed ? ds.text : ds.textSecondary),
                ),
        ),
      ),
    );
    final onDown = widget.onPointerDown;
    return onDown == null ? field : Listener(onPointerDown: (_) => onDown(), child: field);
  }
}
