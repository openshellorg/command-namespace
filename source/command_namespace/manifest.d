/// Load registration manifests (JSON5; plain JSON is valid JSON5) into nodes (NS-2).
module command_namespace.manifest;

import std.json;
import std.conv : to;
import command_namespace.node;
import command_namespace.json5 : parseJSON5, JSON5Exception;
import command_namespace.registry : RegistrationError;

/// Parse a manifest document and return its claims as nodes.
/// Validates the subset of registration-manifest.schema.json the registry depends on.
Node[] parseManifest(string text, string sourceName = "manifest")
{
    JSONValue j;
    try j = parseJSON5(text);
    catch (JSON5Exception e) throw new RegistrationError(sourceName ~ ":" ~ e.msg);
    catch (JSONException e) throw new RegistrationError(sourceName ~ ": not valid JSON5: " ~ e.msg);
    if (j.type != JSONType.object) throw new RegistrationError(sourceName ~ ": manifest must be an object");

    auto ver = "manifest" in j;
    if (ver is null || ver.type != JSONType.integer || ver.integer != 0)
        throw new RegistrationError(sourceName ~ ": \"manifest\" must be 0 (provisional format)");

    auto pkg = "package" in j;
    if (pkg is null || pkg.type != JSONType.object || ("id" in *pkg) is null || ("version" in *pkg) is null)
        throw new RegistrationError(sourceName ~ ": \"package\" needs id and version");
    string pkgId = (*pkg)["id"].str, pkgVer = (*pkg)["version"].str;

    auto policy = ConflictPolicy.refuse;
    if (auto p = "conflict-policy" in j)
    {
        if (p.str == "shadow-with-warning") policy = ConflictPolicy.shadowWithWarning;
        else if (p.str != "refuse") throw new RegistrationError(sourceName ~ ": unknown conflict-policy '" ~ p.str ~ "'");
    }

    auto cl = "claims" in j;
    if (cl is null || cl.type != JSONType.array || cl.array.length == 0)
        throw new RegistrationError(sourceName ~ ": \"claims\" must be a non-empty array");

    Node[] r;
    foreach (i, c; cl.array)
    {
        auto where = sourceName ~ ": claims[" ~ i.to!string ~ "]";
        if (c.type != JSONType.object || ("path" in c) is null || ("kind" in c) is null)
            throw new RegistrationError(where ~ " needs path and kind");
        Node n;
        n.path = c["path"].str;
        if (!isValidPath(n.path)) throw new RegistrationError(where ~ ": invalid path '" ~ n.path ~ "'");
        if (!parseKind(c["kind"].str, n.kind)) throw new RegistrationError(where ~ ": unknown kind '" ~ c["kind"].str ~ "'");
        if (auto s = "summary" in c) n.summary = s.str;
        if (auto t = "target" in c) n.target = t.str;
        if (n.kind == NodeKind.alias_ && !isValidPath(n.target)) throw new RegistrationError(where ~ ": alias needs a valid target");
        if (auto e = "entry" in c)
        {
            foreach (a; (*e)["argv"].array) n.argv ~= a.str;
            if (auto st = "style" in *e)
            {
                if (st.str != "strict" && st.str != "resolver") throw new RegistrationError(where ~ ": unknown style '" ~ st.str ~ "'");
                n.style = st.str;
            }
        }
        n.ownerPackage = pkgId;
        n.ownerVersion = pkgVer;
        n.source = "manifest:" ~ pkgId ~ "@" ~ pkgVer;
        n.policy = policy;
        r ~= n;
    }
    return r;
}

unittest
{
    import std.file : readText, exists;
    import std.exception : assertThrown;
    import command_namespace.registry : Registry, ResolveStatus;

    auto path = "examples/npm.manifest.json5";
    assert(exists(path), "run tests from the repository root");
    auto nodes = parseManifest(readText(path), path);
    assert(nodes.length == 2);
    assert(nodes[0].path == "install/npm" && nodes[0].kind == NodeKind.provider);
    assert(nodes[0].source == "manifest:npm@10.9.0");

    auto reg = new Registry;
    foreach (n; nodes) reg.register(n);
    assert(reg.resolve("npm").node.path == "install/npm");

    assertThrown!RegistrationError(parseManifest(`{"manifest":1}`));
    assertThrown!RegistrationError(parseManifest(`{"manifest":0,"package":{"id":"x","version":"1"},"claims":[{"path":"BAD","kind":"command"}]}`));
    assertThrown!RegistrationError(parseManifest(`not json`));
    assert(reg.resolve("install/npm").status == ResolveStatus.found);
    // JSON5 conveniences in a manifest
    auto n2 = parseManifest(`{manifest: 0, package: {id: 'x', version: '1'}, // c
        claims: [{path: 'tool', kind: 'command',},],}`);
    assert(n2.length == 1 && n2[0].path == "tool");
    assertThrown!RegistrationError(parseManifest(`{manifest: 0, x: Infinity}`));
}
