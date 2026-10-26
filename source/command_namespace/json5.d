/// Small JSON5-to-JSON translator, so manifests parse with std.json (PROVISIONAL dependency choice).
/// Supports: // and /* */ comments, trailing commas, unquoted (identifier) keys, single-quoted strings,
/// line continuations and \x / single-char escapes in strings, hex integers, leading '+', leading or
/// trailing decimal point. Infinity and NaN are rejected: the JSON data model (and JSON Schema) has no
/// place for them.
module command_namespace.json5;

import std.array : appender, Appender;
import std.ascii : isDigit, isHexDigit, isAlpha, isAlphaNum, isWhite;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, parseJSON;

class JSON5Exception : Exception
{
    size_t line, column;
    this(string msg, size_t line, size_t column, string file = __FILE__, size_t ln = __LINE__) @safe pure
    {
        super(format("%s:%s: %s", line, column, msg), file, ln);
        this.line = line;
        this.column = column;
    }
}

/// Parse JSON5 text into a JSONValue.
JSONValue parseJSON5(string text)
{
    return parseJSON(json5ToJson(text));
}

/// Translate JSON5 text to equivalent strict JSON text.
string json5ToJson(string s) @safe
{
    auto t = Translator(s);
    t.skipWs();
    t.value();
    t.skipWs();
    if (t.i < s.length) t.fail("unexpected text after the top-level value");
    return t.o.data;
}

private struct Translator
{
    string s;
    size_t i;
    Appender!string o;

    this(string s) @safe { this.s = s; o = appender!string(); }

    void fail(string msg) @safe
    {
        size_t line = 1, col = 1;
        foreach (c; s[0 .. i < s.length ? i : s.length])
        {
            if (c == '\n') { line++; col = 1; } else col++;
        }
        throw new JSON5Exception(msg, line, col);
    }

    bool more() @safe { return i < s.length; }
    char peek(size_t k = 0) @safe { return i + k < s.length ? s[i + k] : '\0'; }

    void skipWs() @safe
    {
        while (more())
        {
            auto c = peek();
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v') { i++; continue; }
            if (c == 0xEF && peek(1) == 0xBB && peek(2) == 0xBF) { i += 3; continue; } // BOM
            if (c == '/' && peek(1) == '/') { while (more() && peek() != '\n') i++; continue; }
            if (c == '/' && peek(1) == '*')
            {
                i += 2;
                while (more() && !(peek() == '*' && peek(1) == '/')) i++;
                if (!more()) fail("unterminated block comment");
                i += 2;
                continue;
            }
            break;
        }
    }

    void value() @safe
    {
        if (!more()) fail("expected a value");
        auto c = peek();
        if (c == '{') return object();
        if (c == '[') return array();
        if (c == '"' || c == '\'') return str();
        if (c == '-' || c == '+' || c == '.' || isDigit(c)) return number();
        if (isAlpha(c))
        {
            auto w = ident();
            if (w == "true" || w == "false" || w == "null") { o.put(w); return; }
            if (w == "Infinity" || w == "NaN") fail(w ~ " is not allowed in manifests (no JSON equivalent)");
            fail("unexpected word '" ~ w ~ "'");
        }
        fail("unexpected character '" ~ c ~ "'");
    }

    string ident() @safe
    {
        auto st = i;
        if (!(isAlpha(peek()) || peek() == '_' || peek() == '$')) fail("expected a key");
        while (more() && (isAlphaNum(peek()) || peek() == '_' || peek() == '$')) i++;
        return s[st .. i];
    }

    void object() @safe
    {
        i++; o.put('{');
        bool first = true;
        while (true)
        {
            skipWs();
            if (peek() == '}') { i++; o.put('}'); return; }
            if (!first)
            {
                if (peek() != ',') fail("expected ',' or '}'");
                i++; skipWs();
                if (peek() == '}') { i++; o.put('}'); return; } // trailing comma
                o.put(',');
            }
            first = false;
            if (peek() == '"' || peek() == '\'') str();
            else { o.put('"'); o.put(ident()); o.put('"'); }
            skipWs();
            if (peek() != ':') fail("expected ':' after key");
            i++; o.put(':');
            skipWs();
            value();
        }
    }

    void array() @safe
    {
        i++; o.put('[');
        bool first = true;
        while (true)
        {
            skipWs();
            if (peek() == ']') { i++; o.put(']'); return; }
            if (!first)
            {
                if (peek() != ',') fail("expected ',' or ']'");
                i++; skipWs();
                if (peek() == ']') { i++; o.put(']'); return; }
                o.put(',');
            }
            first = false;
            value();
        }
    }

    void str() @safe
    {
        auto q = peek();
        i++;
        o.put('"');
        while (true)
        {
            if (!more()) fail("unterminated string");
            auto c = peek();
            if (c == q) { i++; o.put('"'); return; }
            if (c == '\n' || c == '\r') fail("newline in string (use \\ at line end to continue)");
            if (c == '"') { o.put(`\"`); i++; continue; }
            if (c != '\\') { o.put(c); i++; continue; }
            i++;
            auto e = peek();
            switch (e)
            {
                case '\n': i++; break;
                case '\r': i++; if (peek() == '\n') i++; break;
                case '\'': o.put('\''); i++; break;
                case '"': o.put(`\"`); i++; break;
                case 'x':
                    if (!isHexDigit(peek(1)) || !isHexDigit(peek(2))) fail("bad \\x escape");
                    o.put(`\u00`); o.put(s[i + 1 .. i + 3]); i += 3; break;
                case 'u':
                    foreach (k; 1 .. 5) if (!isHexDigit(peek(k))) fail("bad \\u escape");
                    o.put(s[i - 1 .. i + 5]); i += 5; break;
                case 'b', 'f', 'n', 'r', 't', '\\', '/':
                    o.put('\\'); o.put(e); i++; break;
                case 'v': o.put(`\u000b`); i++; break;
                case '0':
                    if (isDigit(peek(1))) fail("octal escapes are not allowed");
                    o.put(`\u0000`); i++; break;
                default:
                    if (!more()) fail("unterminated string");
                    o.put(e); i++; // JSON5: any other escaped char is itself
            }
        }
    }

    void number() @safe
    {
        bool neg;
        if (peek() == '+' || peek() == '-') { neg = peek() == '-'; i++; }
        if (isAlpha(peek()))
        {
            auto w = ident();
            fail(w ~ " is not allowed in manifests (no JSON equivalent)");
        }
        if (peek() == '0' && (peek(1) == 'x' || peek(1) == 'X'))
        {
            i += 2;
            auto st = i;
            while (more() && isHexDigit(peek())) i++;
            if (st == i) fail("bad hex number");
            ulong v = s[st .. i].to!ulong(16);
            if (neg) o.put('-');
            o.put(v.to!string);
            return;
        }
        if (neg) o.put('-');
        auto st = i;
        while (more() && isDigit(peek())) i++;
        auto intPart = s[st .. i];
        if (intPart.length > 1 && intPart[0] == '0') fail("leading zeros are not allowed");
        o.put(intPart.length ? intPart : "0");
        if (peek() == '.')
        {
            i++;
            auto fs = i;
            while (more() && isDigit(peek())) i++;
            if (fs == i && intPart.length == 0) fail("bad number");
            if (fs != i) { o.put('.'); o.put(s[fs .. i]); }
        }
        else if (intPart.length == 0) fail("bad number");
        if (peek() == 'e' || peek() == 'E')
        {
            o.put('e'); i++;
            if (peek() == '+' || peek() == '-') { o.put(peek()); i++; }
            auto es = i;
            while (more() && isDigit(peek())) i++;
            if (es == i) fail("bad exponent");
            o.put(s[es .. i]);
        }
    }
}

unittest
{
    import std.exception : assertThrown;
    auto j = parseJSON5(`
        // line comment
        {
          unquoted: 'single "quoted"',
          /* block */ "quoted": [1, 2, 3,],
          hex: 0xFF, neg: -0x10, plus: +1, lead: .5, trail: 5., exp: 1e3,
          esc: 'it\'s \x41 \
continued',
          nested: { a: null, b: true, c: false, },
        }
    `);
    assert(j["unquoted"].str == `single "quoted"`);
    assert(j["quoted"].array.length == 3);
    assert(j["hex"].integer == 255);
    assert(j["neg"].integer == -16);
    assert(j["plus"].integer == 1);
    assert(j["lead"].floating == 0.5);
    assert(j["trail"].integer == 5);
    assert(j["exp"].floating == 1000);
    assert(j["esc"].str == "it's A continued");
    assert(j["nested"]["a"].isNull && j["nested"]["b"].boolean);
    // plain JSON is valid JSON5
    assert(parseJSON5(`{"a": [1, "x"]}`)["a"][1].str == "x");

    assertThrown!JSON5Exception(json5ToJson(`{a: Infinity}`));
    assertThrown!JSON5Exception(json5ToJson(`{a: NaN}`));
    assertThrown!JSON5Exception(json5ToJson(`{a: 1 b: 2}`));
    assertThrown!JSON5Exception(json5ToJson(`{a: 'x`));
    assertThrown!JSON5Exception(json5ToJson(`[1,,2]`));
    assertThrown!JSON5Exception(json5ToJson(`/* open`));
    assertThrown!JSON5Exception(json5ToJson(`{a: 01}`));
    assertThrown!JSON5Exception(json5ToJson(`{} x`));
    try { json5ToJson("{\n  a: ?\n}"); assert(0); }
    catch (JSON5Exception e) assert(e.line == 2);
}
