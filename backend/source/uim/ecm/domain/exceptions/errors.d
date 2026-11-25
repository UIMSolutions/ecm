/// Business exceptions. Presentation adapters map them to HTTP status codes.
module uim.ecm.domain.exceptions.errors;

class DomainException : Exception { this(string msg) pure nothrow @safe { super(msg); } }
class NotFoundException : DomainException { this(string msg) pure nothrow @safe { super(msg); } }
class ValidationException : DomainException { this(string msg) pure nothrow @safe { super(msg); } }
class ConflictException : DomainException { this(string msg) pure nothrow @safe { super(msg); } }
class UnauthorizedException : DomainException { this(string msg) pure nothrow @safe { super(msg); } }
class ForbiddenException : DomainException { this(string msg) pure nothrow @safe { super(msg); } }
