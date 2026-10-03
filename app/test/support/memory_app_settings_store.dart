import 'package:herdr_mobile/data/repositories/app_settings.dart';

/// Keeps app settings in memory and records what was written.
class MemoryAppSettingsStore implements AppSettingsStore {
  MemoryAppSettingsStore([this.theme]);

  ThemeChoice? theme;
  final writes = <String>[];

  @override
  Future<ThemeChoice?> readTheme() async => theme;

  @override
  Future<void> writeTheme(ThemeChoice value) async {
    theme = value;
    writes.add('theme ${value.name}');
  }
}
