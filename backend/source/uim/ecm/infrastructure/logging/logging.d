/// Technical logging setup on top of vibe.core.log.
module uim.ecm.infrastructure.logging.logging;

import vibe.core.log;

void configureLogging(string level)
{
    switch (level)
    {
        case "trace": setLogLevel(LogLevel.trace); break;
        case "debug": setLogLevel(LogLevel.debug_); break;
        case "warn": setLogLevel(LogLevel.warn); break;
        case "error": setLogLevel(LogLevel.error); break;
        default: setLogLevel(LogLevel.info); break;
    }
}
