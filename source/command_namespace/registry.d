/// Reference registry: records claims, resolves names, reports conflicts (NS-2..NS-5).
module command_namespace.registry;

import std.algorithm : sort, map, filter, all, startsWith, min;
import std.algorithm.comparison : levenshteinDistance;
import std.array : array;
import std.exception : enforce;
import std.typecons : Tuple, tuple;
import command_namespace.node;

/// Thrown for a malformed registration (bad path, alias without target).
class RegistrationError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow { super(msg, file, line); }
}

/// Why a path has more than one claim.
enum ConflictKind
{
    refused,  /// at least one claimant refuses sharing: a real conflict (NS-3)
    shadowed  /// every claimant allows ordered shadowing (e.g. PATH import); first wins, always reported
}

struct Conflict
{
    string path;
    ConflictKind kind;
    Node[] claims; /// in registration order; claims[0] wins when kind == shadowed
}

enum ResolveStatus { found, notFound, ambiguous, aliasLoop }

struct Resolution
{
    ResolveStatus status;
    Node node;            /// winning claim (found)
    string[] chain;       /// paths followed, including aliases
    Node[] others;        /// shadowed or competing claims at the final path
}

/// In-memory registry. Registration order is meaningful for shadowing.
class Registry
{
    private Node[][string] claims_;
    private string[] order_;

    /// Record one claim. Validates the path and alias target (NS-1, NS-2).
    void register(Node n) @safe
    {
        if (!isValidPath(n.path))
            throw new RegistrationError("invalid node path '" ~ n.path ~ "'");
        if (n.kind == NodeKind.alias_ && !isValidPath(n.target))
            throw new RegistrationError("alias '" ~ n.path ~ "' needs a valid target");
        if (n.path !in claims_) order_ ~= n.path;
        claims_[n.path] ~= n;
    }

    /// Every path with at least one claim, sorted.
    string[] paths() @safe
    {
        auto p = order_.dup;
        p.sort();
        return p;
    }

    /// All claims on a path, in registration order.
    Node[] claimsOf(string path) @safe
    {
        if (auto c = path in claims_) return (*c).dup;
        return null;
    }

    /// Direct children of `path` ("" for the root).
    string[] children(string path) @safe
    {
        string[] r;
        foreach (p; paths())
            if (parentOf(p) == path) r ~= p;
        return r;
    }

    /// Resolve a path, following aliases. Ambiguity (NS-3) is never resolved silently.
    Resolution resolve(string path) @safe
    {
        Resolution r;
        bool[string] seen;
        string cur = path;
        while (true)
        {
            if (cur in seen) { r.status = ResolveStatus.aliasLoop; return r; }
            seen[cur] = true;
            r.chain ~= cur;
            auto c = cur in claims_;
            if (c is null) { r.status = ResolveStatus.notFound; return r; }
            auto list = *c;
            if (list.length > 1 && !list.all!(x => x.policy == ConflictPolicy.shadowWithWarning))
            {
                r.status = ResolveStatus.ambiguous;
                r.others = list.dup;
                return r;
            }
            auto win = list[0];
            if (win.kind == NodeKind.alias_) { cur = win.target; continue; }
            r.status = ResolveStatus.found;
            r.node = win;
            r.others = list[1 .. $].dup;
            return r;
        }
    }

    /// Every path claimed more than once, sorted by path.
    Conflict[] conflicts() @safe
    {
        Conflict[] r;
        foreach (p; paths())
        {
            auto list = claims_[p];
            if (list.length < 2) continue;
            auto k = list.all!(x => x.policy == ConflictPolicy.shadowWithWarning)
                ? ConflictKind.shadowed : ConflictKind.refused;
            r ~= Conflict(p, k, list.dup);
        }
        return r;
    }

    /// Did-you-mean candidates for an unknown name, matched on the last word (NS-4).
    string[] suggest(string name, size_t max = 3) @safe
    {
        Tuple!(size_t, string)[] scored;
        foreach (p; paths())
        {
            auto leaf = p[(parentOf(p).length ? parentOf(p).length + 1 : 0) .. $];
            auto d = min(levenshteinDistance(name, leaf), levenshteinDistance(name, p));
            auto limit = name.length <= 3 ? 1 : (name.length <= 6 ? 2 : 3);
            if (d <= limit) scored ~= tuple(d, p);
        }
        scored.sort();
        return scored[0 .. min(max, scored.length)].map!(t => t[1]).array;
    }
}

@safe unittest
{
    auto r = new Registry;
    r.register(Node("install", NodeKind.verb));
    r.register(Node("install/npm", NodeKind.provider, "npm", "npm", "10.9.0", ["npm"]));
    Node a = { path: "npm", kind: NodeKind.alias_, target: "install/npm" };
    r.register(a);

    auto res = r.resolve("npm");
    assert(res.status == ResolveStatus.found);
    assert(res.node.path == "install/npm");
    assert(res.chain == ["npm", "install/npm"]);
    assert(r.children("") == ["install", "npm"]);
    assert(r.children("install") == ["install/npm"]);
    assert(r.resolve("nope").status == ResolveStatus.notFound);
    assert(r.suggest("instal") == ["install"]);
    assert(r.conflicts().length == 0);
}

@safe unittest
{
    // NS-3: two refusing claims are ambiguous, never last-wins.
    auto r = new Registry;
    Node a = { path: "python", source: "pkg-a" };
    Node b = { path: "python", source: "pkg-b" };
    r.register(a);
    r.register(b);
    auto res = r.resolve("python");
    assert(res.status == ResolveStatus.ambiguous);
    assert(res.others.length == 2);
    auto c = r.conflicts();
    assert(c.length == 1 && c[0].kind == ConflictKind.refused);
}

@safe unittest
{
    // Ordered shadowing (PATH import): first wins, others reported.
    auto r = new Registry;
    Node a = { path: "legacy/git", source: "legacy:PATH:A", policy: ConflictPolicy.shadowWithWarning };
    Node b = { path: "legacy/git", source: "legacy:PATH:B", policy: ConflictPolicy.shadowWithWarning };
    r.register(a);
    r.register(b);
    auto res = r.resolve("legacy/git");
    assert(res.status == ResolveStatus.found && res.node.source == "legacy:PATH:A");
    assert(res.others.length == 1);
    assert(r.conflicts()[0].kind == ConflictKind.shadowed);
}

@safe unittest
{
    import std.exception : assertThrown;
    auto r = new Registry;
    assertThrown!RegistrationError(r.register(Node("Bad Path")));
    Node a = { path: "x", kind: NodeKind.alias_ };
    assertThrown!RegistrationError(r.register(a));
    Node l1 = { path: "a", kind: NodeKind.alias_, target: "b" };
    Node l2 = { path: "b", kind: NodeKind.alias_, target: "a" };
    r.register(l1);
    r.register(l2);
    assert(r.resolve("a").status == ResolveStatus.aliasLoop);
}
