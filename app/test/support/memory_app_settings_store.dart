import 'package:herdr_mobile/data/repositories/app_settings.dart';

/// Keeps app settings in memory and records what was written.
class MemoryAppSettingsStore implements AppSettingsStore {
  MemoryAppSettingsStore([this.theme]);

  ThemeChoice? theme;
  bool? darkTerminal;
  int? homeTab;
  BoardDensity? density;
  OpenAgentsAs? openAgentsAs;
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

  @override
  Future<BoardDensity?> readDensity() async => density;

  @override
  Future<void> writeDensity(BoardDensity value) async {
    density = value;
    writes.add('density ${value.name}');
  }

  @override
  Future<OpenAgentsAs?> readOpenAgentsAs() async => openAgentsAs;

  @override
  Future<void> writeOpenAgentsAs(OpenAgentsAs value) async {
    openAgentsAs = value;
    writes.add('openAgentsAs ${value.name}');
  }

  bool? smoothText;

  @override
  Future<bool?> readSmoothText() async => smoothText;

  @override
  Future<void> writeSmoothText(bool value) async {
    smoothText = value;
    writes.add('smoothText $value');
  }
}
