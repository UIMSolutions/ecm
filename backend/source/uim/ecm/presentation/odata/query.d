/// OData system query options on top of Json arrays:
/// $filter (eq ne gt ge lt le, contains/startswith/endswith, 'and'),
/// $orderby, $top, $skip, $count.
module uim.ecm.presentation.odata.query;

import std.algorithm.comparison : cmp;
import std.algorithm.iteration : filter, map;
import std.algorithm.mutation : SwapStrategy;
import std.algorithm.searching : all, canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, replace, split;
import std.conv : ConvException, to;
import std.regex : matchFirst, regex;
import std.string : strip, toLower;
import vibe.data.json;
import vibe.http.server : HTTPServerRequest;
import uim.ecm.domain;

struct QueryOptions { long top = -1; long skip = 0; bool count; string filterExpr; string orderby; }
struct QueryResult { Json[] page; long total; }

QueryOptions parseOptions(HTTPServerRequest req)
{
    QueryOptions o;
    try
    {
        auto t = req.query.get("$top", "");
        auto s = req.query.get("$skip", "");
        if (t.length) o.top = t.to!long;
        if (s.length) o.skip = s.to!long;
    }
    catch (ConvException) { throw new ValidationException("$top and $skip must be integers"); }
    o.count = req.query.get("$count", "") == "true";
    o.filterExpr = req.query.get("$filter", "");
    o.orderby = req.query.get("$orderby", "");
    return o;
}

QueryResult applyQuery(Json[] items, QueryOptions o)
{
    if (o.filterExpr.length)
    {
        auto preds = splitAnd(o.filterExpr).map!(t => compileTerm(t)).array;
        items = items.filter!(i => preds.all!(p => p(i))).array;
    }
    if (o.orderby.length)
    {
        struct Key { string field; bool desc; }
        Key[] keys;
        foreach (part; o.orderby.split(","))
        {
            auto w = part.strip.split(" ");
            if (w.length == 0 || w[0].length == 0) continue;
            keys ~= Key(w[0], w.length > 1 && w[1].toLower == "desc");
        }
        items.sort!((a, b) {
            foreach (k; keys)
            {
                int c = compareLoose(a[k.field], b[k.field]);
                if (c != 0) return k.desc ? c > 0 : c < 0;
            }
            return false;
        }, SwapStrategy.stable);
    }
    long total = items.length;
    long s = o.skip < 0 ? 0 : (o.skip > total ? total : o.skip);
    long e = (o.top >= 0 && s + o.top < total) ? s + o.top : total;
    return QueryResult(items[cast(size_t) s .. cast(size_t) e], total);
}

private string[] splitAnd(string s)
{
    string[] parts;
    string cur;
    bool inQuote;
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '\'') { inQuote = !inQuote; cur ~= s[i]; i++; continue; }
        if (!inQuote && s[i .. $].startsWith(" and ")) { parts ~= cur.strip; cur = ""; i += 5; continue; }
        cur ~= s[i];
        i++;
    }
    parts ~= cur.strip;
    return parts;
}

private bool isStr(Json v) { return v.type == Json.Type.string; }
private bool isNum(Json v) { return v.type == Json.Type.int_ || v.type == Json.Type.float_; }
private bool isBool(Json v) { return v.type == Json.Type.bool_; }
private bool isNull(Json v) { return v.type == Json.Type.undefined || v.type == Json.Type.null_; }

private bool comparable(Json a, Json b)
{
    return (isStr(a) && isStr(b)) || (isNum(a) && isNum(b)) || (isBool(a) && isBool(b));
}

private int compareJson(Json a, Json b)
{
    if (isStr(a) && isStr(b)) return cmp(a.get!string, b.get!string);
    if (isNum(a) && isNum(b))
    {
        double x = a.to!double, y = b.to!double;
        return x < y ? -1 : (x > y ? 1 : 0);
    }
    if (isBool(a) && isBool(b)) return a.get!bool == b.get!bool ? 0 : (a.get!bool ? 1 : -1);
    return 0;
}

private int compareLoose(Json a, Json b)
{
    if (isNull(a) || isNull(b)) return isNull(a) == isNull(b) ? 0 : (isNull(a) ? -1 : 1);
    return compareJson(a, b);
}

private Json parseLiteral(string s)
{
    if (s.length >= 2 && s[0] == '\'' && s[$ - 1] == '\'') return Json(s[1 .. $ - 1].replace("''", "'"));
    if (s == "true") return Json(true);
    if (s == "false") return Json(false);
    if (s == "null") return Json(null);
    try return Json(s.to!double);
    catch (ConvException) return Json(s); // e.g. unquoted ISO date
}

private bool delegate(Json) compileTerm(string term)
{
    auto fn = matchFirst(term, regex(`^(contains|startswith|endswith)\((\w+)\s*,\s*'((?:[^']|'')*)'\)$`));
    if (!fn.empty)
    {
        string op = fn[1].idup, field = fn[2].idup, val = fn[3].replace("''", "'").toLower;
        return (Json item) {
            auto v = item[field];
            if (!isStr(v)) return false;
            auto s = v.get!string.toLower;
            if (op == "contains") return s.canFind(val);
            if (op == "startswith") return s.startsWith(val);
            return s.endsWith(val);
        };
    }
    auto cm = matchFirst(term, regex(`^(\w+)\s+(eq|ne|gt|ge|lt|le)\s+(.+)$`));
    if (cm.empty) throw new ValidationException("Unsupported $filter expression: " ~ term);
    string field = cm[1].idup, op = cm[2].idup;
    Json lit = parseLiteral(cm[3].idup.strip);
    return (Json item) {
        auto v = item[field];
        if (lit.type == Json.Type.null_) return isNull(v) == (op == "eq");
        if (!comparable(v, lit)) return op == "ne";
        int c = compareJson(v, lit);
        switch (op)
        {
            case "eq": return c == 0;
            case "ne": return c != 0;
            case "gt": return c > 0;
            case "ge": return c >= 0;
            case "lt": return c < 0;
            default: return c <= 0;
        }
    };
}

/// Extracts a top-level "Field eq 'value'" term from $filter so the use case can answer it from a
/// repository index instead of scanning. The full $filter is still applied afterwards, so this is
/// purely an optimisation and never changes the result.
string pushdown(string filterExpr, string field)
{
    if (filterExpr.length == 0) return "";
    foreach (term; splitAnd(filterExpr))
    {
        auto m = matchFirst(term, regex(`^` ~ field ~ `\s+eq\s+'((?:[^']|'')*)'$`));
        if (!m.empty) return m[1].replace("''", "'");
    }
    return "";
}
