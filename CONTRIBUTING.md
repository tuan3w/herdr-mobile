# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- Read [AGENTS.md](AGENTS.md): the principles every change is judged by
  (who the app is for, attention, safety, honesty about stale data).
- For anything bigger than a small fix, open an issue first so we can agree
  on the shape before you spend time on it.
- Run `tool/check.sh` before you open a pull request; CI runs the same check.
- UI changes: include renders with worst-case data (long names, offline,
  dark theme), see `.agents/skills/herdr-screen-check`.

## Licensing of contributions

herdr mobile is licensed under the [GNU GPL v3.0](LICENSE). By submitting a
contribution (code, documentation, assets or anything else) you agree that:

1. Your contribution is licensed under the GPL v3.0, like the rest of the
   project.
2. You also grant Tuan Nguyen (the maintainer) a perpetual, worldwide,
   non-exclusive, royalty-free, irrevocable license to use, modify, sublicense
   and distribute your contribution under other terms, including commercial
   or proprietary licenses. This keeps the project able to offer commercial
   licenses alongside the GPL; the GPL version stays available either way.
3. You wrote the contribution yourself, or otherwise have the right to submit
   it under these terms, and it does not include code you are not allowed to
   license this way.

If you can't agree to point 2, say so in your pull request before it is
merged and we'll find another way.
