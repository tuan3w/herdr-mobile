# md-bench

The markdown engine bench-off that picked `package:markdown` for the chat. Not part of the app.

```
./fetch_flutter_md.sh                  # copies flutter_md 0.2.0 (6e31935) parser files to lib/fmd/ (gitignored)
dart pub get                           # needs the Flutter SDK on PATH (herdr_mobile path dependency)
dart run bin/score.dart                # correctness of B, C and D (ours) on app/test/markdown/corpus
dart run bin/score.dart -v name        # diffs of failing cases
dart build cli -t bin/speed.dart -o /tmp/md_speed_build && /tmp/md_speed_build/bundle/bin/speed   # AOT timings; run from this folder
```

(`dart compile exe` refuses this package graph because of a build-hook package
pulled in by the app; `dart build cli` works.) The files import each other by
relative path across the repo, which `dart analyze` of this package cannot
resolve; running them works.

Engine A, the file viewer's own parser, was deleted when the renderer replaced
it; its numbers were measured at commit `a9ab81a`
(`app/lib/ui/features/files/markdown.dart`).
