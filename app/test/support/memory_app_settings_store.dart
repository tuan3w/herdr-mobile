import 'package:herdr_mobile/data/repositories/app_settings.dart';

/// Keeps app settings in memory and records what was written.
class MemoryAppSettingsStore implements AppSettingsStore {
  MemoryAppSettingsStore([this.theme]);

  ThemeChoice? theme;
  bool? darkTerminal;
  int? homeTab;
  final writes = <String>[];

  @override
  Future<ThemeChoice?> readTheme() async => theme;

  @override
  Future<void> writeTheme(ThemeChoice value) async {
    theme = value;
    writes.add('theme ${value.name}');
  }

  @override
  Future<bool?> readDarkTerminal() async => darkTerminal;

  @override
  Future<void> writeDarkTerminal(bool dark) async {
    darkTerminal = dark;
    writes.add('darkTerminal $dark');
  }

  @override
  Future<int?> readHomeTab() async => homeTab;

  @override
  Future<void> writeHomeTab(int tab) async {
    homeTab = tab;
    writes.add('homeTab $tab');
  }
}
