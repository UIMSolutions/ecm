/// In-memory inverted index, safe for many concurrent readers (reader/writer lock).
/// Field boosts: name x3, title x2, content x1. All terms must match (AND); the last term
/// also matches as a prefix. Exact terms are hash lookups; prefixes use a sorted vocabulary
/// (binary search), so a query never scans the whole index. Tokenising happens outside the lock.
module uim.ecm.persistence.storages.searchindex;

import core.sync.rwmutex : ReadWriteMutex;
import std.algorithm.mutation : removeAt = remove;
import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.array : insertInPlace, replace;
import std.math : log;
import std.string : CaseSensitive, indexOf, strip;
import std.uni : isAlphaNum, toLower;
import uim.ecm.ports;

private struct Entry { string tenantId, name, title, text; string[] terms; }

final class InMemorySearchIndex : SearchIndex
{
    private enum maxPrefixTerms = 64;

    private Entry[string] entries;
    private double[string][string] postings; // term -> docId -> weight
    private string[] vocabulary;             // sorted terms
    private ReadWriteMutex rw;

    this() { rw = new ReadWriteMutex(ReadWriteMutex.Policy.PREFER_WRITERS); }

    void clear()
    {
        rw.writer.lock();
        scope(exit) rw.writer.unlock();
        entries = null;
        postings = null;
        vocabulary = null;
    }

    void index(string id, string tenantId, string name, string title, string text)
    {
        double[string] weights; // CPU-heavy part first, without holding the lock
        foreach (t; tokenize(name)) addTo(weights, t, 3.0);
        foreach (t; tokenize(title)) addTo(weights, t, 2.0);
        foreach (t; tokenize(text)) addTo(weights, t, 1.0);

        rw.writer.lock();
        scope(exit) rw.writer.unlock();
        removeLocked(id);
        foreach (t, w; weights)
        {
            auto weight = 1.0 + log(w);
            if (auto p = t in postings) (*p)[id] = weight;
            else { double[string] m; m[id] = weight; postings[t] = m; insertTerm(t); }
        }
        entries[id] = Entry(tenantId, name, title, text, weights.keys);
    }

    void remove(string id)
    {
        rw.writer.lock();
        scope(exit) rw.writer.unlock();
        removeLocked(id);
    }

    SearchHit[] search(string tenantId, string query, size_t limit)
    {
        auto qt = tokenize(query);
        if (qt.length == 0) return [];

        rw.reader.lock();
        scope(exit) rw.reader.unlock();
        double n = entries.length;
        double[string] scores;
        foreach (i, q; qt)
        {
            double[string] part;
            void collect(string term, double factor)
            {
                auto posting = term in postings;
                if (posting is null) return;
                double idf = log(1.0 + n / (*posting).length);
                foreach (id, w; *posting)
                    if (entries[id].tenantId == tenantId) // hard tenant isolation
                        addTo(part, id, w * idf * factor);
            }
            collect(q, 1.0);
            if (i + 1 == qt.length) // prefix expansion for the last term only
            {
                auto lo = lowerBound(q);
                size_t taken;
                for (auto j = lo; j < vocabulary.length && taken < maxPrefixTerms && vocabulary[j].startsWith(q); j++)
                    if (vocabulary[j] != q) { collect(vocabulary[j], 0.6); taken++; }
            }
            if (i == 0) scores = part;
            else foreach (id; scores.keys)
            {
                if (auto p = id in part) scores[id] += *p;
                else scores.remove(id);
            }
        }
        SearchHit[] hits;
        foreach (id, s; scores) hits ~= SearchHit(id, s, "");
        hits.sort!((a, b) => a.score > b.score || (a.score == b.score && a.id < b.id));
        if (hits.length > limit) hits = hits[0 .. limit];
        foreach (ref h; hits) h.snippet = snippetFor(entries[h.id], qt);
        return hits;
    }

    // ---- internals (callers hold the lock) ----
    private void removeLocked(string id)
    {
        auto e = id in entries;
        if (e is null) return;
        foreach (t; e.terms)
            if (auto p = t in postings)
            {
                (*p).remove(id);
                if ((*p).length == 0) { postings.remove(t); eraseTerm(t); }
            }
        entries.remove(id);
    }

    private size_t lowerBound(string t)
    {
        size_t lo = 0, hi = vocabulary.length;
        while (lo < hi)
        {
            auto mid = (lo + hi) / 2;
            if (vocabulary[mid] < t) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    private void insertTerm(string t) { vocabulary.insertInPlace(lowerBound(t), t); }

    private void eraseTerm(string t)
    {
        auto i = lowerBound(t);
        if (i < vocabulary.length && vocabulary[i] == t) vocabulary = removeAt(vocabulary, i);
    }
}

private void addTo(ref double[string] m, string key, double v)
{
    if (auto p = key in m) *p += v;
    else m[key] = v;
}

private string[] tokenize(string s)
{
    string[] tokens;
    string cur;
    void flush()
    {
        if (cur.length >= 2 && cur.length <= 64) tokens ~= cur;
        cur = null;
    }
    foreach (dchar c; s)
    {
        if (isAlphaNum(c)) cur ~= toLower(c);
        else flush();
    }
    flush();
    return tokens;
}

private string snippetFor(Entry e, string[] terms)
{
    auto text = e.text.length ? e.text : e.title;
    ptrdiff_t pos = -1;
    foreach (t; terms)
    {
        auto i = text.indexOf(t, CaseSensitive.no);
        if (i >= 0 && (pos < 0 || i < pos)) pos = i;
    }
    if (pos < 0) pos = 0;
    size_t start = pos > 70 ? pos - 70 : 0;
    size_t end = start + 200 > text.length ? text.length : start + 200;
    while (start > 0 && (text[start] & 0xC0) == 0x80) start--;
    while (end < text.length && (text[end] & 0xC0) == 0x80) end++;
    auto s = text[start .. end].replace("\r", " ").replace("\n", " ").replace("\t", " ").strip;
    return (start > 0 ? "…" : "") ~ s ~ (end < text.length ? "…" : "");
}
