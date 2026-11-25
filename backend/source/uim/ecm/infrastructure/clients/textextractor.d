/// Extracts searchable text: plain text formats, HTML/XML, and OOXML/ODF (zip+xml).
/// PDF and scanned documents are not supported (add an OCR/PDF adapter behind TextExtractor).
module uim.ecm.infrastructure.clients.textextractor;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : appender, replace;
import std.string : toLower;
import std.utf : validate;
import std.zip : ZipArchive;
import uim.ecm.ports;

final class DefaultTextExtractor : TextExtractor
{
    private enum maxInput = 20 * 1024 * 1024;
    private enum maxText = 2 * 1024 * 1024;

    string extract(string mimeType, string fileName, const(ubyte)[] data)
    {
        if (data.length == 0 || data.length > maxInput) return "";
        auto name = fileName.toLower;
        auto mime = mimeType.toLower;
        try
        {
            string text;
            if (name.endsWith(".docx")) text = zipXml(data, ["word/document.xml"]);
            else if (name.endsWith(".odt") || name.endsWith(".ods") || name.endsWith(".odp"))
                text = zipXml(data, ["content.xml"]);
            else if (name.endsWith(".xlsx")) text = zipXml(data, ["xl/sharedStrings.xml"]);
            else if (name.endsWith(".pptx")) text = zipXmlPrefix(data, "ppt/slides/slide");
            else if (isPlainText(mime, name))
            {
                auto s = cast(string) data.idup;
                validate(s);
                bool markup = mime.canFind("html") || mime.canFind("xml")
                    || name.endsWith(".html") || name.endsWith(".htm") || name.endsWith(".xml");
                text = markup ? stripMarkup(s) : s;
            }
            if (text.length > maxText)
            {
                size_t n = maxText;
                while (n > 0 && (text[n] & 0xC0) == 0x80) n--;
                text = text[0 .. n];
            }
            return text;
        }
        catch (Exception) { return ""; }
    }

    private static bool isPlainText(string mime, string name)
    {
        if (mime.startsWith("text/") || mime.canFind("json") || mime.canFind("xml")
            || mime.canFind("yaml") || mime.canFind("javascript") || mime.canFind("csv"))
            return true;
        foreach (ext; [".txt", ".md", ".csv", ".tsv", ".json", ".xml", ".yaml", ".yml", ".log", ".html", ".htm", ".ini", ".conf"])
            if (name.endsWith(ext)) return true;
        return false;
    }

    private static string zipXml(const(ubyte)[] data, string[] members)
    {
        auto zip = new ZipArchive(cast(void[]) data.dup);
        auto sb = appender!string;
        foreach (n; members)
            if (auto am = n in zip.directory)
            {
                if (am.expandedSize > 50 * 1024 * 1024) continue;
                sb ~= stripMarkup(cast(string) zip.expand(*am).idup);
                sb ~= " ";
            }
        return sb.data;
    }

    private static string zipXmlPrefix(const(ubyte)[] data, string prefix)
    {
        auto zip = new ZipArchive(cast(void[]) data.dup);
        auto sb = appender!string;
        auto names = zip.directory.keys;
        names.sort();
        foreach (n; names)
            if (n.startsWith(prefix) && n.endsWith(".xml"))
            {
                auto am = zip.directory[n];
                if (am.expandedSize > 50 * 1024 * 1024) continue;
                sb ~= stripMarkup(cast(string) zip.expand(am).idup);
                sb ~= " ";
            }
        return sb.data;
    }

    private static string stripMarkup(string s)
    {
        auto sb = appender!string;
        bool inTag;
        foreach (char c; s)
        {
            if (c == '<') { inTag = true; sb ~= ' '; }
            else if (c == '>') inTag = false;
            else if (!inTag) sb ~= c;
        }
        return sb.data.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", "\"").replace("&apos;", "'").replace("&nbsp;", " ");
    }
}
