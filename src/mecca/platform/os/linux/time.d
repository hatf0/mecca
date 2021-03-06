module mecca.platform.os.linux.time;

version (linux):
package(mecca):

struct Timer
{
@nogc:

    import core.sys.posix.signal : siginfo_t;
    import core.sys.posix.time : timer_t;
    import core.time : Duration;

    import mecca.platform.os.linux : OSSignal;

    alias Callback = extern (C) void function();

    private
    {
        Duration interval;
        Callback callback;

        OSSignal hangDetectorSig;
        timer_t hangDetectorTimerId;
    }

    this(Duration interval, Callback callback) nothrow
    in
    {
        assert(callback !is null);
    }
    do
    {
        this.interval = interval;
        this.callback = callback;
    }

    void start() @trusted
    {
        import core.sys.posix.signal : SA_ONSTACK,
            SA_RESTART, SA_SIGINFO, sigaction, sigaction_t, sigevent, signal,
            SIGRTMIN, SIG_DFL;

        import core.sys.posix.time : CLOCK_MONOTONIC, itimerspec, timer_create,
            timer_delete, timer_settime;

        import mecca.lib.exception : DBG_ASSERT, ASSERT, errnoEnforceNGC;
        import mecca.log : INFO;
        import mecca.platform.os.linux : gettid;

        hangDetectorSig = cast(OSSignal)SIGRTMIN;
        scope(failure) hangDetectorSig = OSSignal.init;

        sigaction_t sa;
        sa.sa_flags = SA_RESTART | SA_ONSTACK | SA_SIGINFO;
        sa.sa_sigaction = cast(typeof(sa.sa_sigaction)) callback;
        errnoEnforceNGC(sigaction(hangDetectorSig, &sa, null) == 0, "sigaction() for registering hang detector signal failed");
        scope(failure) signal(hangDetectorSig, SIG_DFL);

        enum SIGEV_THREAD_ID = 4;
        // SIGEV_THREAD_ID (Linux-specific)
        // As  for  SIGEV_SIGNAL, but the signal is targeted at the thread whose ID is given in sigev_notify_thread_id,
        // which must be a thread in the same process as the caller.  The sigev_notify_thread_id field specifies a kernel
        // thread ID, that is, the value returned by clone(2) or gettid(2).  This flag is intended only for use by
        // threading libraries.

        sigevent sev;
        sev.sigev_notify = SIGEV_THREAD_ID;
        sev.sigev_signo = hangDetectorSig;
        sev.sigev_value.sival_ptr = &hangDetectorTimerId;
        sev._sigev_un._tid = gettid();

        errnoEnforceNGC(timer_create(CLOCK_MONOTONIC, &sev, &hangDetectorTimerId) == 0,
                "timer_create for hang detector");
        ASSERT!"hangDetectorTimerId is null"(hangDetectorTimerId !is timer_t.init);
        scope(failure) timer_delete(hangDetectorTimerId);

        itimerspec its;

        interval.split!("seconds", "nsecs")(its.it_value.tv_sec, its.it_value.tv_nsec);
        its.it_interval = its.it_value;
        INFO!"Hang detector will wake up every %s seconds and %s nsecs"(its.it_interval.tv_sec, its.it_interval.tv_nsec);

        errnoEnforceNGC(timer_settime(hangDetectorTimerId, 0, &its, null) == 0, "timer_settime");
    }

    void cancel() @trusted nothrow
    {
        import core.sys.posix.signal : signal, SIG_DFL;
        import core.sys.posix.time : timer_delete;

        if (hangDetectorSig is OSSignal.SIGNONE)
            return; // Hang detector was not initialized

        timer_delete(hangDetectorTimerId);
        signal(hangDetectorSig, SIG_DFL);
        hangDetectorSig = OSSignal.init;
    }

    bool isSet() const pure @safe nothrow
    {
        return hangDetectorSig != OSSignal.SIGNONE;
    }
}

auto calculateCycles()
{
    import core.sys.posix.signal : timespec;
    import core.sys.posix.time: clock_gettime, CLOCK_MONOTONIC, nanosleep;

    import std.exception: enforce, errnoEnforce;
    import std.file: readText;
    import std.string: indexOf;
    import std.typecons: tuple;

    import mecca.platform.x86: readTSC;

    enforce(readText("/proc/cpuinfo").indexOf("constant_tsc") >= 0,
        "constant_tsc not supported");

    timespec sleepTime = timespec(0, 200_000_000);
    timespec t0, t1;

    auto rc1 = clock_gettime(CLOCK_MONOTONIC, &t0);
    auto cyc0 = readTSC();
    auto rc2 = nanosleep(&sleepTime, null);
    auto rc3 = clock_gettime(CLOCK_MONOTONIC, &t1);
    auto cyc1 = readTSC();

    errnoEnforce(rc1 == 0, "clock_gettime");
    errnoEnforce(rc2 == 0, "nanosleep");   // we hope we won't be interrupted by a signal here
    errnoEnforce(rc3 == 0, "clock_gettime");

    const nsecs = (t1.tv_sec - t0.tv_sec) * 1_000_000_000UL +
        (t1.tv_nsec  - t0.tv_nsec);
    const cyclesPerSecond = cast(long)((cyc1 - cyc0) / (nsecs / 1E9));
    const cyclesPerMsec = cyclesPerSecond / 1_000;
    const cyclesPerUsec = cyclesPerSecond / 1_000_000;

    return tuple!("perSecond", "perMsec", "perUsec")(
        cyclesPerSecond, cyclesPerMsec, cyclesPerUsec);
}
