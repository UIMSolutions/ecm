module uim.ecm.infrastructure.clients.system;

import core.time : Duration;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.uuid : randomUUID;
import uim.ecm.ports;

final class UuidGenerator : IdGenerator
{
    string next() { return randomUUID().toString(); }
}

final class UtcClock : TimeSource
{
    SysTime now()
    {
        auto t = Clock.currTime(UTC());
        t.fracSecs = Duration.zero;
        return t;
    }
}
