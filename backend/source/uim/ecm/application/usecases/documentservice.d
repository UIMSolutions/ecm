module uim.ecm.application.usecases.documentservice;

import std.algorithm.iteration : filter;
import std.array : array;
import uim.ecm.application.services.accesspolicy;
import uim.ecm.application.dtos;
import uim.ecm.ports.usecases;
import uim.ecm.ports;
import uim.ecm.domain;

final class DocumentService : DocumentUseCases
{
    private enum maxExtractBytes = 20UL * 1024 * 1024;

    private DocumentRepository docs;
    private FolderRepository folders;
    private ContentStore store;
    private IdGenerator ids;
    private TimeSource time;
    private SearchIndex index;
    private TextExtractor extractor;
    private AccessPolicy access;
    private BackgroundExecutor background;
    private EventPublisher events;

    this(DocumentRepository docs, FolderRepository folders, ContentStore store, IdGenerator ids,
         TimeSource time, SearchIndex index, TextExtractor extractor, AccessPolicy access,
         BackgroundExecutor background, EventPublisher events)
    {
        this.docs = docs; this.folders = folders; this.store = store; this.ids = ids;
        this.time = time; this.index = index; this.extractor = extractor; this.access = access;
        this.background = background;
        this.events = events;
    }

    // ---- guards ----
    private void guard(Principal who, string workspaceId, Role min, string what, string id)
    {
        try { access.require(who, workspaceId, min); }
        catch (NotFoundException) { throw new NotFoundException(what ~ " '" ~ id ~ "' not found"); }
    }

    private Folder loadFolder(Principal who, string id, Role min)
    {
        Folder f;
        if (!folders.find(id, f)) throw new NotFoundException("Folder '" ~ id ~ "' not found");
        guard(who, f.workspaceId, min, "Folder", id);
        return f;
    }

    private Document loadDocument(Principal who, string id, Role min)
    {
        Document d;
        if (!docs.find(id, d)) throw new NotFoundException("Document '" ~ id ~ "' not found");
        guard(who, d.workspaceId, min, "Document", id);
        return d;
    }

    /// The folder must exist in the given workspace (folders never cross workspaces).
    private void requireFolderIn(string folderId, string workspaceId)
    {
        Folder f;
        if (!folders.find(folderId, f) || f.workspaceId != workspaceId)
            throw new ValidationException("Folder does not exist in this workspace");
    }

    private void checkParent(string workspaceId, string selfId, string parentId)
    {
        for (auto cur = parentId; cur.length; )
        {
            Folder p;
            if (!folders.find(cur, p) || p.workspaceId != workspaceId)
                throw new ValidationException("Invalid parent folder");
            if (cur == selfId)
                throw new ValidationException("A folder cannot be moved into itself or its subfolders");
            cur = p.parentId;
        }
    }

    // ---- folders ----
    Folder[] listFolders(Principal who, string workspaceId)
    {
        if (workspaceId.length)
        {
            access.require(who, workspaceId, Role.viewer);
            return folders.inWorkspace(workspaceId);
        }
        Folder[] result;
        foreach (wsId, _; access.accessible(who)) result ~= folders.inWorkspace(wsId);
        return result;
    }

    Folder getFolder(Principal who, string id) { return loadFolder(who, id, Role.viewer); }

    Folder createFolder(Principal who, string workspaceId, string name, string parentId)
    {
        access.require(who, workspaceId, Role.editor);
        requireValidName("Folder", name);
        if (parentId.length) checkParent(workspaceId, "", parentId);
        Folder f;
        f.id = ids.next(); f.workspaceId = workspaceId; f.parentId = parentId;
        f.name = name; f.createdAt = time.now();
        folders.save(f);
        return f;
    }

    Folder updateFolder(Principal who, string id, FolderPatch p)
    {
        auto f = loadFolder(who, id, Role.editor);
        if (!p.name.isNull) { requireValidName("Folder", p.name.get); f.name = p.name.get; }
        if (!p.parentId.isNull)
        {
            checkParent(f.workspaceId, id, p.parentId.get);
            f.parentId = p.parentId.get;
        }
        folders.save(f);
        return f;
    }

    void deleteFolder(Principal who, string id)
    {
        loadFolder(who, id, Role.editor);
        if (folders.childrenOf(id).length > 0 || docs.inFolder(id).length > 0)
            throw new ConflictException("Folder is not empty");
        folders.remove(id);
    }

    // ---- documents ----
    Document[] listDocuments(Principal who, DocumentFilter f)
    {
        if (f.workspaceId.length)
        {
            access.require(who, f.workspaceId, Role.viewer);
            if (f.folderId.length)
                return docs.inFolder(f.folderId).filter!(d => d.workspaceId == f.workspaceId).array;
            return docs.inWorkspace(f.workspaceId);
        }
        Document[] result;
        foreach (wsId, _; access.accessible(who)) result ~= docs.inWorkspace(wsId);
        return result;
    }

    Document getDocument(Principal who, string id) { return loadDocument(who, id, Role.viewer); }

    Document createDocument(Principal who, NewDocument n)
    {
        auto ws = access.require(who, n.workspaceId, Role.editor);
        requireValidName("Document", n.name);
        if (n.folderId.length) requireFolderIn(n.folderId, ws.id);
        Document d;
        d.id = ids.next();
        d.tenantId = ws.tenantId;
        d.workspaceId = ws.id;
        d.folderId = n.folderId;
        d.name = n.name;
        d.title = n.title.length ? n.title : n.name;
        if (n.mimeType.length) d.mimeType = n.mimeType;
        d.createdBy = who.username;
        d.createdAt = d.modifiedAt = time.now();
        docs.save(d);
        scheduleIndex(d.id);
        return d;
    }

    Document updateDocument(Principal who, string id, DocumentPatch p)
    {
        auto d = loadDocument(who, id, Role.editor);
        d.ensureMutable();
        if (!p.name.isNull) { requireValidName("Document", p.name.get); d.name = p.name.get; }
        if (!p.title.isNull) d.title = p.title.get;
        if (!p.folderId.isNull)
        {
            if (p.folderId.get.length) requireFolderIn(p.folderId.get, d.workspaceId);
            d.folderId = p.folderId.get;
        }
        d.modifiedAt = time.now();
        docs.save(d);
        scheduleIndex(d.id);
        return d;
    }

    void deleteDocument(Principal who, string id)
    {
        loadDocument(who, id, Role.editor);
        store.remove(id);
        docs.remove(id);
        index.remove(id);
    }

    // ---- content (streamed) ----
    Document uploadContent(Principal who, string id, ByteSource src, string mimeType)
    {
        auto d = loadDocument(who, id, Role.editor);
        d.ensureMutable();
        auto bytes = store.put(id, src);
        d.replaceContent(cast(long) bytes, mimeType, time.now());
        docs.save(d);
        scheduleIndex(d.id);
        return d;
    }

    ContentInfo contentInfo(Principal who, string id)
    {
        auto d = loadDocument(who, id, Role.viewer);
        ulong bytes;
        if (!store.size(id, bytes)) throw new NotFoundException("Document has no content yet");
        return ContentInfo(d.mimeType, d.name, bytes);
    }

    void readContent(Principal who, string id, ByteSink sink)
    {
        loadDocument(who, id, Role.viewer);
        if (!store.copyTo(id, sink)) throw new NotFoundException("Document has no content yet");
    }

    Document publish(Principal who, string id)
    {
        auto d = loadDocument(who, id, Role.editor);
        d.publish(time.now());
        docs.save(d);
        events.toWorkspace(who, d.workspaceId, "document.published", d.name, d.id, "");
        return d;
    }

    Document archive(Principal who, string id)
    {
        auto d = loadDocument(who, id, Role.editor);
        d.archive(time.now());
        docs.save(d);
        events.toWorkspace(who, d.workspaceId, "document.archived", d.name, d.id, "");
        return d;
    }

    // ---- full-text search (tenant-isolated in the index, workspace-filtered here) ----
    DocumentHit[] searchDocuments(Principal who, string query, size_t limit)
    {
        access.requireTenantMember(who);
        auto acc = access.accessible(who);
        DocumentHit[] result;
        foreach (hit; index.search(who.tenantId, query, 2000))
        {
            Document d;
            if (docs.find(hit.id, d) && (d.workspaceId in acc) !is null)
            {
                result ~= DocumentHit(d, hit.score, hit.snippet);
                if (result.length >= limit) break;
            }
        }
        return result;
    }

    /// Rebuilds the index in the background (platform or tenant administrators); returns the number of documents queued.
    size_t reindexAll(Principal who)
    {
        if (!who.isPlatformAdmin && !who.isTenantAdmin) throw new ForbiddenException("Administrator required");
        index.clear();
        size_t n;
        foreach (d; docs.all()) { scheduleIndex(d.id); n++; }
        return n;
    }

    // ---- indexing runs off the request threads and always indexes the latest stored state ----
    private void scheduleIndex(string id)
    {
        background.post({ indexNow(id); });
    }

    private void indexNow(string id)
    {
        Document d;
        if (!docs.find(id, d)) { index.remove(id); return; }
        ubyte[] data;
        string text;
        if (store.readLimited(id, maxExtractBytes, data)) text = extractor.extract(d.mimeType, d.name, data);
        index.index(d.id, d.tenantId, d.name, d.title, text);
    }
}
