import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/models/release_history.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/settings/release_history_screen.dart';

const _sample = '''
# Changelog

Intro text.

## [Unreleased]

- Not a release yet.

## [0.2.0] - 2026-11-01

[![Watch what's new · 1 change · 0:10 · 3 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.2.0/0.2.0-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.2.0/0.2.0-whats-new.mp4)

### Pictures stay on the phone

A picture you opened is kept.

> [!TIP]
> Try it: in Settings, open `Storage`.

- At most 192 MB is kept.

## [0.1.9] - 2026-10-01

No headline here, just words.

## [0.1.8]

### Old and undated

- Something.
''';

void main() {
  group('the changelog as releases', () {
    test('releases come newest first, with their headline and date; Unreleased isn’t one', () {
      final r = parseChangelog(_sample);
      expect([for (final x in r) x.version], ['0.2.0', '0.1.9', '0.1.8']);
      expect(r[0].headline, 'Pictures stay on the phone');
      expect(r[0].date, '2026-11-01');
      expect(r[1].headline, '', reason: 'a section without a ### heading has none');
      expect(r[2].date, '');
      expect(r[0].notes, contains('Try it: in Settings'));
      expect(r[0].notes, isNot(contains('## [0.2.0]')));
      expect(r[0].notes, isNot(contains('Not a release yet')));
    });

    test('a release that leads with a walkthrough has its clip', () {
      final r = parseChangelog(_sample);
      expect(r[0].clip, isNotNull);
      expect(r[1].clip, isNull);
    });

    test('the bundled notes are the repository’s CHANGELOG.md, and the newest release is this version', () async {
      final bundled = await rootBundle.loadString('assets/CHANGELOG.md');
      expect(bundled, File('../CHANGELOG.md').readAsStringSync(), reason: 'assets/CHANGELOG.md is a link to it');
      final releases = parseChangelog(bundled);
      expect(releases, isNotEmpty);
      expect(releases.first.version, appVersion, reason: 'a release adds its section before the version is bumped');
      for (final r in releases) {
        expect(r.headline, isNotEmpty, reason: '${r.version} has a ### headline: the list shows it');
        expect(r.date, isNotEmpty, reason: '${r.version} has a date');
      }
    });
  });

  group('the screen', () {
    Future<void> pump(WidgetTester tester, Future<String> Function() load) async {
      tester.view
        ..physicalSize = const Size(412 * 2.625, 892 * 2.625)
        ..devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: ReleaseHistoryScreen(load: load),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('lists each release with its headline, marks the installed one, and opens its notes', (tester) async {
      final sample = _sample.replaceFirst('[0.2.0]', '[$appVersion]');
      await pump(tester, () async => sample);
      expect(find.text('$appVersion · Installed'), findsOneWidget);
      expect(find.text('Pictures stay on the phone'), findsOneWidget);
      expect(find.text('0.1.9'), findsOneWidget);
      expect(find.text('No headline'), findsOneWidget);

      await tester.tap(find.text('Pictures stay on the phone'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('What’s new in $appVersion'), findsOneWidget);
      expect(find.textContaining('Try it: in Settings'), findsOneWidget, reason: 'the tip card is in the notes');
    });

    testWidgets('says so when the notes can’t be read, instead of an empty page', (tester) async {
      await pump(tester, () async => throw const FileSystemException('gone'));
      expect(find.text('The release notes couldn’t be read on this phone.'), findsOneWidget);
    });
  });
}
