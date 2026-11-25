/// Pure business rules for names (no I/O).
module uim.ecm.domain.services.naming;

import std.algorithm.searching : canFind;
import uim.ecm.domain.exceptions;

/// Shared naming rule for folders and documents.
void requireValidName(string kind, string name)
{
    if (name.length == 0 || name.length > 255)
        throw new ValidationException(kind ~ " name must have 1-255 characters");
    if (name.canFind('/') || name.canFind('\\'))
        throw new ValidationException(kind ~ " name must not contain slashes");
}

unittest
{
    import std.exception : assertThrown;
    requireValidName("Folder", "Contracts");
    assertThrown!ValidationException(requireValidName("Folder", ""));
    assertThrown!ValidationException(requireValidName("Folder", "a/b"));
}
