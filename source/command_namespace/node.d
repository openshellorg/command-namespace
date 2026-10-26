/// Namespace node model and node-path rules (NS-1).
module command_namespace.node;

import std.algorithm : all, canFind;
import std.array : split;
import std.ascii : isLower, isDigit;

/// What a node is. `alias_` because `alias` is a D keyword; serialized as "alias".
enum NodeKind { verb, provider, command, alias_, group }

/// How a second claim on the same path is treated (NS-3). Never silent.
enum ConflictPolicy { refuse, shadowWithWarning }

string kindName(NodeKind k) @safe pure nothrow
{
    final switch (k)
    {
        case NodeKind.verb: return "verb";
        case NodeKind.provider: return "provider";
        case NodeKind.command: return "command";
        case NodeKind.alias_: return "alias";
        case NodeKind.group: return "group";
    }
}

/// Parse a kind name; returns false on unknown names.
bool parseKind(string s, out NodeKind k) @safe pure nothrow
{
    switch (s)
    {
        case "verb": k = NodeKind.verb; return true;
        case "provider": k = NodeKind.provider; return true;
        case "command": k = NodeKind.command; return true;
        case "alias": k = NodeKind.alias_; return true;
        case "group": k = NodeKind.group; return true;
        default: return false;
    }
}

/// One claim on a node path, as written in a manifest or produced by an importer.
struct Node
{
    string path;
    NodeKind kind = NodeKind.command;
    string summary;
    string ownerPackage;
    string ownerVersion;
    string[] argv;          /// entry argv; empty for groups and aliases
    string style = "strict"; /// CLI Styles: strict (default, CS-1) or resolver
    string target;          /// alias target path
    string source;          /// where the claim came from: manifest id, or "legacy:PATH:<dir>"
    ConflictPolicy policy = ConflictPolicy.refuse;
}

private bool isWordStart(dchar c) @safe pure nothrow { return (c < 0x80) && (isLower(cast(char) c) || isDigit(cast(char) c)); }
private bool isWordChar(dchar c) @safe pure nothrow { return isWordStart(c) || c == '.' || c == '_' || c == '+' || c == '-'; }

/// True when `w` is one valid path word (same rule as the JSON Schema pattern).
bool isValidWord(string w) @safe pure
{
    if (w.length == 0 || !isWordStart(w[0])) return false;
    return w[1 .. $].all!(c => isWordChar(c));
}

/// True when `p` is a valid node path: slash-separated valid words.
bool isValidPath(string p) @safe pure
{
    if (p.length == 0) return false;
    return p.split('/').all!(w => isValidWord(w));
}

/// Parent path, or "" for a top-level node.
string parentOf(string p) @safe pure nothrow
{
    foreach_reverse (i, c; p) if (c == '/') return p[0 .. i];
    return "";
}

@safe unittest
{
    assert(isValidPath("install"));
    assert(isValidPath("install/npm"));
    assert(isValidPath("legacy/python3.11"));
    assert(isValidPath("legacy/g++"));
    assert(!isValidPath(""));
    assert(!isValidPath("Install"));
    assert(!isValidPath("install//npm"));
    assert(!isValidPath("/install"));
    assert(!isValidPath("-x"));
    assert(parentOf("install/npm") == "install");
    assert(parentOf("install") == "");
    NodeKind k;
    assert(parseKind("alias", k) && k == NodeKind.alias_ && kindName(k) == "alias");
    assert(!parseKind("nope", k));
}
