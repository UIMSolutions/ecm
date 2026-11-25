/// Small fixed thread pool for background work (text extraction, indexing).
/// When the queue is full the job runs inline, which gives natural back-pressure.
module uim.ecm.infrastructure.workers.threadpool;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.stdio : stderr;
import uim.ecm.ports;

final class ThreadPoolExecutor : BackgroundExecutor
{
    private Mutex mtx;
    private Condition cond;
    private void delegate()[] queue;
    private bool stopping;
    private Thread[] threads;
    private size_t maxQueue;

    this(size_t workers, size_t maxQueue = 50_000)
    {
        this.maxQueue = maxQueue;
        mtx = new Mutex;
        cond = new Condition(mtx);
        foreach (i; 0 .. (workers == 0 ? 1 : workers))
        {
            auto t = new Thread(&run);
            t.isDaemon = true;
            t.start();
            threads ~= t;
        }
    }

    void post(void delegate() job)
    {
        bool inline;
        synchronized (mtx)
        {
            if (queue.length >= maxQueue) inline = true;
            else queue ~= job;
        }
        if (inline) { safeRun(job); return; }
        cond.notify();
    }

    /// Finishes queued jobs and stops the workers.
    void shutdown()
    {
        synchronized (mtx) { stopping = true; }
        cond.notifyAll();
        foreach (t; threads) t.join();
    }

    private void run()
    {
        for (;;)
        {
            void delegate() job;
            synchronized (mtx)
            {
                while (queue.length == 0 && !stopping) cond.wait();
                if (queue.length == 0) return;
                job = queue[0];
                queue = queue[1 .. $];
            }
            safeRun(job);
        }
    }

    private static void safeRun(void delegate() job)
    {
        try job();
        catch (Throwable e) { stderr.writeln("ECM background job failed: ", e.msg); }
    }
}
