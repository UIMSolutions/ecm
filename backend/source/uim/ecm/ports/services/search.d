/// Driven ports for full-text search.
module uim.ecm.ports.services.search;

struct SearchHit { string id; double score; string snippet; }

interface SearchIndex
{
    void index(string id, string tenantId, string name, string title, string text);
    void remove(string id);
    SearchHit[] search(string tenantId, string query, size_t limit);
    void clear();
}

interface TextExtractor
{
    string extract(string mimeType, string fileName, const(ubyte)[] data);
}
