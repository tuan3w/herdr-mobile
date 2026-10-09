// The words of background work: nouns and plurals, the strip's table, the
// waiting sentence, the toast, ordering of finished tasks.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/ui/features/agent_session/background_format.dart';

BackgroundTask task(
  String id, {
  BackgroundKind kind = BackgroundKind.shell,
  BackgroundStatus status = BackgroundStatus.running,
  DateTime? startedAt,
  DateTime? endedAt,
}) => BackgroundTask(
  id: id,
  kind: kind,
  status: status,
  title: 'run $id',
  startedAt: startedAt,
  endedAt: endedAt,
);

BackgroundWork work(List<BackgroundTask> tasks, {bool wakes = false, String? label, bool unknown = false}) =>
    BackgroundWork(tasks: tasks, wakes: wakes, wakeLabel: label, unknownRunning: unknown);

void main() {
  group('nounPhrase', () {
    test('jobs, singular and plural', () {
      expect(nounPhrase([task('bg_1')]), '1 job');
      expect(nounPhrase([task('bg_1'), task('bg_2')]), '2 jobs');
      expect(nounPhrase([task('bg_1'), task('e', kind: BackgroundKind.eval)]), '2 jobs', reason: 'bash and eval are both jobs');
    });

    test('background terminals', () {
      expect(nounPhrase([task('t', kind: BackgroundKind.terminal)]), '1 background terminal');
      expect(
        nounPhrase([task('t', kind: BackgroundKind.terminal), task('u', kind: BackgroundKind.terminal)]),
        '2 background terminals',
      );
    });

    test('a mix of kinds is background tasks', () {
      expect(
        nounPhrase([task('bg_1'), task('t', kind: BackgroundKind.terminal)]),
        '2 background tasks',
      );
      expect(nounPhrase([task('a', kind: BackgroundKind.agent), task('bg_1')]), '2 background tasks');
    });

    test('other kinds say their own word', () {
      expect(nounPhrase([task('a', kind: BackgroundKind.agent)]), '1 subagent');
      expect(nounPhrase([task('w', kind: BackgroundKind.workflow)]), '1 workflow');
      expect(nounPhrase([task('m', kind: BackgroundKind.monitor), task('n', kind: BackgroundKind.monitor)]), '2 monitors');
      expect(nounPhrase([task('x', kind: BackgroundKind.other)]), '1 background task');
    });
  });

  group('stoppedToast', () {
    test('names what is still running, singular and plural', () {
      expect(stoppedToast(work([task('bg_6')])), 'Turn stopped \u00b7 1 job still running');
      expect(stoppedToast(work([task('bg_6'), task('bg_7')])), 'Turn stopped \u00b7 2 jobs still running');
      expect(
        stoppedToast(work([task('t', kind: BackgroundKind.terminal)])),
        'Turn stopped \u00b7 1 background terminal still running',
      );
      expect(
        stoppedToast(work([task('bg_6'), task('t', kind: BackgroundKind.terminal)])),
        'Turn stopped \u00b7 2 background tasks still running',
      );
    });

    test('nothing running says nothing; unknown work says so', () {
      expect(stoppedToast(BackgroundWork.empty), isNull);
      expect(stoppedToast(work([task('bg_6', status: BackgroundStatus.finished)])), isNull);
      expect(stoppedToast(work(const [], unknown: true)), 'Turn stopped \u00b7 background work still running');
    });
  });

  group('stripText (the States table)', () {
    test('no turn, nothing running: none', () {
      expect(stripText(BackgroundWork.empty, waiting: false, turnRunning: false), isNull);
      expect(stripText(BackgroundWork.empty, waiting: false, turnRunning: true), isNull);
      expect(
        stripText(work([task('bg_1', status: BackgroundStatus.finished)]), waiting: false, turnRunning: false),
        isNull,
        reason: 'only finished work: nothing runs',
      );
    });

    test('turn runs, n running: one line, no promise about waking', () {
      final w = work([task('bg_1'), task('bg_2')], wakes: true, label: 'omp');
      expect(stripText(w, waiting: false, turnRunning: true), const StripText('2 running in background'));
    });

    test('waiting and it wakes: the consequence is the second line', () {
      final w = work([task('bg_6')], wakes: true, label: 'omp');
      expect(
        stripText(w, waiting: true, turnRunning: false),
        const StripText('1 running in background', 'omp continues by itself when it finishes'),
      );
      expect(
        stripText(work([task('a'), task('b')], wakes: true, label: 'Claude'), waiting: true, turnRunning: false)!.secondary,
        'Claude continues by itself when one finishes',
      );
    });

    test('waiting where it does not wake: one line', () {
      expect(
        stripText(work([task('bg_6')]), waiting: true, turnRunning: false),
        const StripText('1 running in background'),
      );
    });

    test('idle with a background terminal and no wake', () {
      expect(
        stripText(work([task('t', kind: BackgroundKind.terminal)]), waiting: false, turnRunning: false),
        const StripText('1 background terminal running'),
      );
    });

    test('unknown: details unavailable', () {
      expect(
        stripText(work(const [], unknown: true), waiting: true, turnRunning: false),
        const StripText('Background work \u00b7 details unavailable'),
      );
      expect(
        stripText(BackgroundWork.empty, waiting: true, turnRunning: false),
        const StripText('Background work \u00b7 details unavailable'),
        reason: 'waiting with an empty list is unknown work, not nothing',
      );
    });

    test('semantics is one sentence ending in how to open it', () {
      expect(
        stripSemantics(work([task('bg_6')]), waiting: false, turnRunning: true),
        'Background work, 1 running, double tap to open',
      );
      expect(
        stripSemantics(work([task('bg_6')], wakes: true, label: 'omp'), waiting: true, turnRunning: false),
        'Background work, 1 running, omp continues by itself when it finishes, double tap to open',
      );
    });
  });

  group('waiting words', () {
    test('one task is named by its id, several by their noun, none by nothing', () {
      expect(waitingSentence(work([task('bg_6')])), 'Waiting for bg_6');
      expect(waitingSentence(work([task('bg_6'), task('bg_7')])), 'Waiting for 2 jobs');
      expect(waitingSentence(work(const [], unknown: true)), 'Waiting for background work');
      expect(waitingSubject(work([task('bg_6', status: BackgroundStatus.finished)])), isNull);
    });

    test('an id from a log is made visible and cut in the middle', () {
      expect(waitingSubject(work([task('bg_\u202E6')])), 'bg_\u2039U+202E\u203a6');
      final long = 'job_${'x' * 60}_end';
      final subject = waitingSubject(work([task(long)]))!;
      expect(subject.length, 24);
      expect(subject, startsWith('job_'));
      expect(subject, endsWith('_end'));
      expect(subject, contains('\u2026'));
    });

    test('elapsed moves by the minute', () {
      expect(backgroundElapsed(const Duration(seconds: 42)), '42s');
      expect(backgroundElapsed(const Duration(minutes: 14, seconds: 59)), '14m');
      expect(backgroundElapsed(const Duration(hours: 4, minutes: 36)), '4h 36m');
      expect(backgroundElapsed(const Duration(hours: 1, minutes: 2)), '1h 02m');
      expect(backgroundElapsed(const Duration(seconds: -5)), '0s');
    });
  });

  group('the sheet words', () {
    test('the consequence sentence, once; none for an agent that does not wake', () {
      expect(wakeSentence(work([task('a')], wakes: true, label: 'omp')), 'omp continues by itself when a job finishes.');
      expect(wakeSentence(work([task('a')], wakes: true, label: 'Claude')), 'Claude continues by itself when a job finishes.');
      expect(wakeSentence(work([task('a')])), isNull);
    });

    test('the stop label says what it does', () {
      expect(stopLabel(StopRoute.direct, 'omp'), 'Stop');
      expect(stopLabel(StopRoute.message, 'omp'), 'Ask to stop');
      expect(stopSemantics(task('bg_6'), 'omp', primed: false), 'Stop bg_6, hold to confirm');
      expect(
        stopSemantics(task('bg_6').copyWith(stop: StopRoute.message), 'omp', primed: false),
        'Ask omp to stop bg_6, hold to confirm',
      );
      expect(stopSemantics(task('bg_6'), 'omp', primed: true), 'Confirm: Stop bg_6, activate again to confirm');
    });

    test('Stop all reports what it could not stop', () {
      expect(stopAllSummary(stopped: 2, skipped: 1, asked: false), 'Stopped 2 \u00b7 1 has no stop control');
      expect(stopAllSummary(stopped: 2, skipped: 3, asked: false), 'Stopped 2 \u00b7 3 have no stop control');
      expect(stopAllSummary(stopped: 2, skipped: 0, asked: true), 'Asked to stop 2');
    });

    test('finished: failed first, then newest first, ties by arrival', () {
      final t0 = DateTime(2026, 1, 1, 10);
      final a = task('a', status: BackgroundStatus.finished, endedAt: t0);
      final b = task('b', status: BackgroundStatus.finished, endedAt: t0.add(const Duration(minutes: 5)));
      final c = task('c', status: BackgroundStatus.failed, endedAt: t0.subtract(const Duration(hours: 1)));
      final d = task('d', status: BackgroundStatus.stopped);
      final e = task('e', status: BackgroundStatus.stopped);
      expect(finishedOrder([a, b, c, d, e]).map((t) => t.id), ['c', 'b', 'a', 'e', 'd']);
    });

    test('a middle cut keeps the end of an id', () {
      expect(shorten('bg_6', 24), 'bg_6');
      expect(shorten('abcdefghij', 6), 'abc\u2026ij');
    });
  });
}
