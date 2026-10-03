import 'package:herdr_mobile/data/repositories/terminal_settings.dart';

/// Keeps settings in memory and records what was written.
class MemoryTerminalSettingsStore implements TerminalSettingsStore {
  double? fontSize;
  bool? wrap;
  final writes = <String>[];

  @override
  Future<({double? fontSize, bool? wrap})> read() async =>
      (fontSize: fontSize, wrap: wrap);

  @override
  Future<void> writeFontSize(double value) async {
    fontSize = value;
    writes.add('font $value');
  }

  @override
  Future<void> writeWrap(bool value) async {
    wrap = value;
    writes.add('wrap $value');
  }
}
