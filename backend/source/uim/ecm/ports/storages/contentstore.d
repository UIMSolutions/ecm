/// Driven port for binary document content.
module uim.ecm.ports.storages.contentstore;

import uim.ecm.ports.storages.streams;

interface ContentStore
{
    /// Streams the content to storage (atomically replacing any previous version); returns the byte count.
    ulong put(string id, ByteSource src);
    bool size(string id, out ulong bytes);
    bool copyTo(string id, ByteSink sink);
    /// Reads the whole content if it exists and is at most maxBytes (used for text extraction).
    bool readLimited(string id, ulong maxBytes, out ubyte[] data);
    void remove(string id);
}
