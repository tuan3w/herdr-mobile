// CPU time of the calling thread (`clock_gettime(CLOCK_THREAD_CPUTIME_ID)`), for
// benchmarks on a shared machine: wall time of a CPU-bound step grows with the
// load of every other process on the box, thread CPU time hardly does. Linux
// and macOS only (libc); it is a desktop tool, like the rest of `benchmark/`.
import 'dart:ffi';
import 'dart:io';

typedef _ClockGettimeC = Int32 Function(Int32, Pointer<Int64>);
typedef _ClockGettime = int Function(int, Pointer<Int64>);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);

final _libc = DynamicLibrary.process();
final _clockGettime = _libc.lookupFunction<_ClockGettimeC, _ClockGettime>('clock_gettime');

/// A `struct timespec` (two 64-bit words), never freed: it lives for the run.
final Pointer<Int64> _spec = _libc.lookupFunction<_MallocC, _Malloc>('malloc')(16).cast<Int64>();
final _threadClock = Platform.isMacOS ? 16 : 3; // CLOCK_THREAD_CPUTIME_ID

/// Microseconds of CPU the calling thread has used so far.
int threadCpuMicros() {
  _clockGettime(_threadClock, _spec);
  return _spec[0] * 1000000 + _spec[1] ~/ 1000;
}

/// A [Stopwatch] on thread CPU time: only the time this thread ran counts.
class CpuWatch {
  var _total = 0;
  int? _from;

  void start() => _from ??= threadCpuMicros();

  void stop() {
    final f = _from;
    if (f != null) _total += threadCpuMicros() - f;
    _from = null;
  }

  void reset() {
    _total = 0;
    _from = null;
  }

  int get elapsedMicroseconds => _total + (_from == null ? 0 : threadCpuMicros() - _from!);
}
