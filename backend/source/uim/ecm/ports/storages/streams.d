/// Minimal streaming abstractions so that large content never has to be buffered in memory.
module uim.ecm.ports.storages.streams;

interface ByteSource
{
    /// Fills buf with the next bytes; returns 0 at the end of the stream.
    size_t read(scope ubyte[] buf);
}

interface ByteSink
{
    void write(scope const(ubyte)[] data);
}
