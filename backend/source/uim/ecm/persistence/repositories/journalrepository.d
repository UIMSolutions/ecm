/// In-memory repository with secondary indexes, guarded by a reader/writer lock so that many
/// worker threads can read concurrently. Durability is an append-only journal (one line per
/// change) written by a background thread in small batches (write-behind). The journal is
/// replayed at startup and compacted when it has grown much larger than the live data.
/// A crash can lose the last flush interval (default 200 ms) of changes.
module uim.ecm.persistence.repositories.journalrepository;

import core.sync.mutex : Mutex;
import core.sync.rwmutex : ReadWriteMutex;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, mkdirRecurse, rename;
import std.path : buildPath;
import std.stdio : File, stderr;
import vibe.data.json;
import uim.ecm.ports;

alias KeyFn(T) = string delegate(const T);

class JournaledRepository(T) : Repository!T
{
    private struct Ix { KeyFn!T fn; bool[string][string] map; } // key -> set of ids

    private T[string] items;
    private Ix[string] indexes;
    private ReadWriteMutex rw;
    private Mutex outLock;
    private string[] pending;
    private bool closing;
    private string path;
    private File journal;
    private Thread flusher;
    private uint flushMs;

    this(string dir, string name, KeyFn!T[string] fns, uint flushMs = 200)
    {
        this.flushMs = flushMs;
        rw = new ReadWriteMutex(ReadWriteMutex.Policy.PREFER_WRITERS);
        outLock = new Mutex;
        foreach (n, fn; fns) indexes[n] = Ix(fn);
        mkdirRecurse(dir);
        path = buildPath(dir, name ~ ".jsonl");

        size_t lines;
        if (exists(path))
            foreach (line; File(path, "r").byLine)
            {
                lines++;
                if (line.length < 2) continue;
                try
                {
                    if (line[0] == 'P') putMem(deserializeJson!T(parseJsonString(line[1 .. $].idup)));
                    else if (line[0] == 'D') dropMem(line[1 .. $].idup);
                }
                catch (Exception) { /* torn last line after a crash */ }
            }
        if (lines > items.length * 2 + 1000) compact();

        journal = File(path, "ab");
        flusher = new Thread(&flushLoop);
        flusher.isDaemon = true;
        flusher.start();
    }

    // ---- Repository!T ----
    T[] all()
    {
        rw.reader.lock();
        scope(exit) rw.reader.unlock();
        return items.values;
    }

    size_t count()
    {
        rw.reader.lock();
        scope(exit) rw.reader.unlock();
        return items.length;
    }

    bool find(string id, out T entity)
    {
        rw.reader.lock();
        scope(exit) rw.reader.unlock();
        if (auto p = id in items) { entity = *p; return true; }
        return false;
    }

    void save(T entity)
    {
        auto line = "P" ~ serializeToJsonString(entity); // serialise outside the lock
        rw.writer.lock();
        scope(exit) rw.writer.unlock();
        putMem(entity);
        enqueue(line); // inside the lock: journal order == memory order
    }

    bool remove(string id)
    {
        rw.writer.lock();
        scope(exit) rw.writer.unlock();
        if (id !in items) return false;
        dropMem(id);
        enqueue("D" ~ id);
        return true;
    }

    /// Entities whose index `name` has the given key.
    T[] findBy(string name, string key)
    {
        rw.reader.lock();
        scope(exit) rw.reader.unlock();
        T[] result;
        if (auto ix = name in indexes)
            if (auto set = key in ix.map)
            {
                result.reserve(set.length);
                foreach (id, _; *set) result ~= items[id];
            }
        return result;
    }

    /// Flushes pending changes and stops the writer thread (call on shutdown).
    void close()
    {
        synchronized (outLock) { closing = true; }
        flusher.join();
        journal.close();
    }

    // ---- internals (callers hold the write lock, or run single-threaded in the constructor) ----
    private void putMem(T e)
    {
        if (auto old = e.id in items) unindex(*old);
        items[e.id] = e;
        foreach (name, ref ix; indexes) addKey(ix, ix.fn(e), e.id);
    }

    private void dropMem(string id)
    {
        if (auto old = id in items) { unindex(*old); items.remove(id); }
    }

    private void unindex(T old)
    {
        foreach (name, ref ix; indexes) delKey(ix, ix.fn(old), old.id);
    }

    private static void addKey(ref Ix ix, string key, string id)
    {
        if (auto set = key in ix.map) (*set)[id] = true;
        else { bool[string] s; s[id] = true; ix.map[key] = s; }
    }

    private static void delKey(ref Ix ix, string key, string id)
    {
        if (auto set = key in ix.map)
        {
            (*set).remove(id);
            if ((*set).length == 0) ix.map.remove(key);
        }
    }

    private void enqueue(string line) { synchronized (outLock) { pending ~= line; } }

    private void compact()
    {
        auto tmp = path ~ ".tmp";
        {
            auto f = File(tmp, "w");
            foreach (e; items) f.writeln("P", serializeToJsonString(e));
        }
        rename(tmp, path);
    }

    private void flushLoop()
    {
        for (;;)
        {
            Thread.sleep(msecs(flushMs));
            string[] batch;
            bool stop;
            synchronized (outLock) { batch = pending; pending = null; stop = closing; }
            if (batch.length)
            {
                try { foreach (l; batch) journal.writeln(l); journal.flush(); }
                catch (Exception e) { stderr.writeln("ECM journal write failed: ", e.msg); }
            }
            if (stop) return;
        }
    }
}
