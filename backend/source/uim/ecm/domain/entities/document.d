module uim.ecm.domain.entities.document;

import std.datetime.systime : SysTime;
import uim.ecm.domain.exceptions;

enum DocumentStatus : string
{
    draft = "Draft",
    published = "Published",
    archived = "Archived"
}

struct Document
{
    string id;
    string tenantId;
    string workspaceId;
    string folderId; // empty = root of the workspace
    string name;
    string title;
    string mimeType = "application/octet-stream";
    string createdBy;
    long size;
    int revision = 1;
    DocumentStatus status = DocumentStatus.draft;
    SysTime createdAt;
    SysTime modifiedAt;

    void ensureMutable() const
    {
        if (status == DocumentStatus.archived)
            throw new ConflictException("Archived documents are read-only");
    }

    void replaceContent(long newSize, string newMime, SysTime now)
    {
        ensureMutable();
        size = newSize;
        mimeType = newMime;
        revision++;
        modifiedAt = now;
    }

    void publish(SysTime now)
    {
        ensureMutable();
        if (size == 0)
            throw new ConflictException("A document without content cannot be published");
        status = DocumentStatus.published;
        modifiedAt = now;
    }

    void archive(SysTime now)
    {
        ensureMutable();
        status = DocumentStatus.archived;
        modifiedAt = now;
    }
}
