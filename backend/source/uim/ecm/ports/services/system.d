/// Driven ports for technical services the application needs.
module uim.ecm.ports.services.system;

import std.datetime.systime : SysTime;

interface IdGenerator { string next(); }
interface TimeSource { SysTime now(); }

/// Runs work off the request threads (indexing, text extraction, notification fan-out).
interface BackgroundExecutor { void post(void delegate() job); }
