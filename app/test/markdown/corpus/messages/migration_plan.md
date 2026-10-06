## Plan: move the session store to SQLite

I checked the three places that touch `SessionStore` (`lib/data/session_store.dart`, `lib/data/repositories/fleet_repository.dart`, and the tests) and propose the order below.

### Steps

1. **Add the dependency.** In `pubspec.yaml`:

   ```yaml
   dependencies:
     sqlite3: ^2.4.0
     path: ^1.9.0
   ```

2. **Create the schema.** One table per aggregate, no ORM:

   ```sql
   CREATE TABLE sessions (
     id TEXT PRIMARY KEY,
     machine TEXT NOT NULL,

     title TEXT,
     updated_at INTEGER NOT NULL
   );

   CREATE INDEX sessions_by_machine ON sessions (machine, updated_at DESC);
   ```

3. **Write the migrator.** It reads the old `prefs` JSON once and inserts rows inside one transaction:
   - if the JSON is malformed, keep the file and log a warning
   - never delete the old data until the next launch has succeeded
   - cap the import at 5 000 rows

4. **Switch the repository** behind the existing `SessionStore` interface, so no screen changes.

5. **Delete the old path** after one release.

### Risks

> The migration runs on the main isolate at start-up.
> A large store could therefore delay the first frame.
>
> > Measure it on the phone, not on the desktop (see `AGENTS.md`).

- Android backups restore `prefs` but not the new database file.
- `sqlite3` needs the native library on Linux desktop builds only.

### Checklist

- [ ] schema reviewed
- [ ] migrator has a test with a 5 000-row fixture
- [x] interface unchanged (`SessionStore`)
- [ ] release note written

### Timing estimate

| Step | Hours | Depends on |
| --- | ---: | --- |
| Dependency | 0.5 | none |
| Schema | 1 | dependency |
| Migrator | 4 | schema |
| Repository | 3 | schema |
| Cleanup | 1 | one release |

Anything you want changed before I start? A **yes** on step 3 is enough; I will not touch step 5 yet.

<details>
<summary>Why not Drift?</summary>

It adds code generation to the build and a second model layer, for six tables.

</details>
