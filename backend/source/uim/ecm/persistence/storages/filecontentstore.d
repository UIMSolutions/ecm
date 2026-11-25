/// Driven adapter: binary content on a (mounted) filesystem, streamed in 64 KiB chunks.
module uim.ecm.persistence.storages.filecontentstore;

import std.file : exists, getSize, mkdirRecurse, rename;
static import std.file;
import std.path : buildPath;
import std.regex : regex, matchFirst;
import std.stdio : File;
import std.uuid : randomUUID;
import uim.ecm.ports;

final class FileContentStore : ContentStore
{
    private enum chunk = 64 * 1024;
    private string dir;

    this(string base)
    {
        dir = buildPath(base, "content");
        mkdirRecurse(dir);
    }

    private string fileFor(string id)
    {
        if (matchFirst(id, regex(`^[A-Za-z0-9-]+$`)).empty)
            throw new Exception("invalid content id");
        return buildPath(dir, id);
    }

    ulong put(string id, ByteSource src)
    {
        auto target = fileFor(id);
        auto tmp = target ~ "." ~ randomUUID().toString() ~ ".tmp";
        ulong total;
        try
        {
            auto f = File(tmp, "wb");
            auto buf = new ubyte[chunk];
            for (;;)
            {
                auto n = src.read(buf);
                if (n == 0) break;
                f.rawWrite(buf[0 .. n]);
                total += n;
            }
            f.close();
        }
        catch (Exception e)
        {
            if (exists(tmp)) std.file.remove(tmp);
            throw e;
        }
        rename(tmp, target); // atomic replace: readers never see a partial file
        return total;
    }

    bool size(string id, out ulong bytes)
    {
        auto f = fileFor(id);
        if (!exists(f)) return false;
        bytes = getSize(f);
        return true;
    }

    bool copyTo(string id, ByteSink sink)
    {
        auto f = fileFor(id);
        if (!exists(f)) return false;
        foreach (c; File(f, "rb").byChunk(chunk)) sink.write(c);
        return true;
    }

    bool readLimited(string id, ulong maxBytes, out ubyte[] data)
    {
        auto f = fileFor(id);
        if (!exists(f) || getSize(f) > maxBytes) return false;
        data = cast(ubyte[]) std.file.read(f);
        return true;
    }

    void remove(string id)
    {
        auto f = fileFor(id);
        if (exists(f)) std.file.remove(f);
    }
}
