/// The version shown in Settings > About. It repeats `version:` in
/// `pubspec.yaml` (without the `+build` number) because the app does not read
/// its own manifest; `test/app_info_test.dart` fails when the two disagree, so
/// bump both together.
const appVersion = '0.1.3';

/// Where the source and releases live.
const appRepositoryUrl = 'https://github.com/tuan3w/herdr-mobile';
