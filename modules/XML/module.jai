#import "Basic";
String :: #import "String";
using String;

XML_Node_Kind :: enum u8 {
    ELEMENT;
    TEXT;
    JAI_HOLE;
}

XML_Attribute :: struct {
    name: string;
    value: string;
}

XML_Node :: struct {
    kind: XML_Node_Kind;
    name: string;
    text: string;
    attributes: [..] XML_Attribute;
    children: [..] *XML_Node;
    self_closing: bool;
}

XML_Parse_Result :: struct {
    roots: [..] *XML_Node;
    error: string;
    error_offset: s64;
}

// Parse a strict XML-like fragment. Text, elements, attributes, comments, and
// balanced `{ Jai code }` holes are retained as a small tree for Template.
parse :: (source: string) -> XML_Parse_Result {
    parser: Parser;
    parser.source = source;
    result: XML_Parse_Result;
    result.roots = parse_children(*parser, "");
    result.error = parser.error;
    result.error_offset = parser.error_offset;
    return result;
}

#scope_file

Parser :: struct {
    source: string;
    at: s64;
    error: string;
    error_offset: s64;
}

decode_entities :: (p: *Parser, text: string) -> string {
    output: String_Builder;
    at: s64;
    while at < text.count {
        if text[at] != #char "&" {
            append(*output, text[at]);
            at += 1;
            continue;
        }

        semicolon := at + 1;
        while semicolon < text.count && text[semicolon] != #char ";" semicolon += 1;
        if semicolon == text.count {
            fail(p, "unclosed XML entity");
            return builder_to_string(*output,, temp);
        }

        entity := slice(text, at + 1, semicolon - at - 1);
        if entity == "amp" append(*output, #char "&");
        else if entity == "lt" append(*output, #char "<");
        else if entity == "gt" append(*output, #char ">");
        else if entity == "quot" append(*output, #char "\"");
        else if entity == "apos" append(*output, #char "'");
        else if begins_with(entity, "#") {
            codepoint: u32;
            digits := slice(entity, 1, entity.count - 1);
            base: u32 = 10;
            if digits.count && (digits[0] == #char "x" || digits[0] == #char "X") {
                base = 16;
                digits = slice(digits, 1, digits.count - 1);
            }
            if digits.count == 0 {
                fail(p, "empty numeric XML entity");
                return builder_to_string(*output,, temp);
            }
            for digit: digits {
                value: u32;
                if digit >= #char "0" && digit <= #char "9" value = cast(u32) (digit - #char "0");
                else if base == 16 && digit >= #char "a" && digit <= #char "f" value = cast(u32) (digit - #char "a" + 10);
                else if base == 16 && digit >= #char "A" && digit <= #char "F" value = cast(u32) (digit - #char "A" + 10);
                else {
                    fail(p, "invalid numeric XML entity");
                    return builder_to_string(*output,, temp);
                }
                if value >= base || codepoint > 0x10ffff / base {
                    fail(p, "numeric XML entity is out of range");
                    return builder_to_string(*output,, temp);
                }
                codepoint = codepoint * base + value;
            }
            if codepoint == 0 || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff) {
                fail(p, "numeric XML entity is not a Unicode scalar value");
                return builder_to_string(*output,, temp);
            }
            if codepoint <= 0x7f append(*output, cast(u8) codepoint);
            else if codepoint <= 0x7ff {
                append(*output, cast(u8) (0xc0 | (codepoint >> 6)));
                append(*output, cast(u8) (0x80 | (codepoint & 0x3f)));
            } else if codepoint <= 0xffff {
                append(*output, cast(u8) (0xe0 | (codepoint >> 12)));
                append(*output, cast(u8) (0x80 | ((codepoint >> 6) & 0x3f)));
                append(*output, cast(u8) (0x80 | (codepoint & 0x3f)));
            } else {
                append(*output, cast(u8) (0xf0 | (codepoint >> 18)));
                append(*output, cast(u8) (0x80 | ((codepoint >> 12) & 0x3f)));
                append(*output, cast(u8) (0x80 | ((codepoint >> 6) & 0x3f)));
                append(*output, cast(u8) (0x80 | (codepoint & 0x3f)));
            }
        } else {
            fail(p, tprint("unknown XML entity `&%;`", entity));
            return builder_to_string(*output,, temp);
        }
        at = semicolon + 1;
    }
    return builder_to_string(*output,, temp);
}

space :: (c: u8) -> bool #no_context {
    return c == #char " " || c == #char "\t" || c == #char "\r" || c == #char "\n";
}

name_byte :: (c: u8) -> bool #no_context {
    return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") ||
        (c >= #char "0" && c <= #char "9") || c == #char "_" || c == #char "-" || c == #char ":" || c == #char ".";
}

starts :: (p: *Parser, text: string) -> bool {
    return p.at + text.count <= p.source.count && slice(p.source, p.at, text.count) == text;
}

fail :: (p: *Parser, message: string) {
    if p.error.count == 0 {
        p.error = message;
        p.error_offset = p.at;
    }
}

skip_space :: (p: *Parser) #no_context {
    while p.at < p.source.count && space(p.source[p.at]) p.at += 1;
}

read_name :: (p: *Parser) -> string {
    start := p.at;
    while p.at < p.source.count && name_byte(p.source[p.at]) p.at += 1;
    return slice(p.source, start, p.at - start);
}

// Braces in quoted strings, line/block comments, and nested Jai blocks do not
// terminate a hole. The returned index points at its matching closing brace.
find_hole_end :: (source: string, open: s64) -> s64 #no_context {
    depth: s64 = 1;
    quote: u8;
    escaped := false;
    line_comment := false;
    block_comment := false;
    i := open + 1;
    while i < source.count {
        c := source[i];
        next := ifx i + 1 < source.count then source[i + 1] else 0;

        if line_comment {
            if c == #char "\n" line_comment = false;
            i += 1;
            continue;
        }
        if block_comment {
            if c == #char "*" && next == #char "/" {
                block_comment = false;
                i += 2;
            } else i += 1;
            continue;
        }
        if quote != 0 {
            if escaped escaped = false;
            else if c == #char "\\" escaped = true;
            else if c == quote quote = 0;
            i += 1;
            continue;
        }

        if c == #char "\"" {
            quote = c;
            i += 1;
        } else if c == #char "/" && next == #char "/" {
            line_comment = true;
            i += 2;
        } else if c == #char "/" && next == #char "*" {
            block_comment = true;
            i += 2;
        } else if c == #char "{" {
            depth += 1;
            i += 1;
        } else if c == #char "}" {
            depth -= 1;
            if depth == 0 return i;
            i += 1;
        } else i += 1;
    }
    return -1;
}

parse_hole :: (p: *Parser) -> *XML_Node {
    open := p.at;
    close := find_hole_end(p.source, open);
    if close < 0 {
        fail(p, "unclosed Jai `{ ... }` hole");
        return null;
    }

    result := New(XML_Node);
    result.kind = .JAI_HOLE;
    result.text = slice(p.source, open + 1, close - open - 1);
    p.at = close + 1;
    return result;
}

parse_comment :: (p: *Parser) {
    p.at += 4; // <!--
    while p.at + 2 < p.source.count && !starts(p, "-->") p.at += 1;
    if p.at + 2 >= p.source.count {
        fail(p, "unclosed XML comment");
        return;
    }
    p.at += 3;
}

parse_element :: (p: *Parser) -> *XML_Node {
    opening := p.at;
    p.at += 1;
    name := read_name(p);
    if name.count == 0 {
        fail(p, "expected an XML element name");
        return null;
    }

    result := New(XML_Node);
    result.kind = .ELEMENT;
    result.name = name;

    while p.at < p.source.count {
        skip_space(p);
        if starts(p, "/>" ) {
            result.self_closing = true;
            p.at += 2;
            return result;
        }
        if starts(p, ">") {
            p.at += 1;
            result.children = parse_children(p, name);
            return result;
        }

        attribute_name := read_name(p);
        if attribute_name.count == 0 {
            fail(p, tprint("expected an attribute or `>` in <%>", name));
            return result;
        }
        skip_space(p);
        if !starts(p, "=") {
            fail(p, tprint("expected `=` after attribute `%`", attribute_name));
            return result;
        }
        p.at += 1;
        skip_space(p);
        if p.at >= p.source.count || (p.source[p.at] != #char "\"" && p.source[p.at] != #char "'") {
            fail(p, tprint("attribute `%` must have a quoted value", attribute_name));
            return result;
        }

        quote := p.source[p.at];
        p.at += 1;
        value_start := p.at;
        while p.at < p.source.count && p.source[p.at] != quote p.at += 1;
        if p.at >= p.source.count {
            fail(p, tprint("unclosed value for attribute `%`", attribute_name));
            return result;
        }
        value := decode_entities(p, slice(p.source, value_start, p.at - value_start));
        p.at += 1;
        array_add(*result.attributes, .{ name = attribute_name, value = value });
    }

    p.at = opening;
    fail(p, tprint("unclosed start tag <%>", name));
    return result;
}

parse_children :: (p: *Parser, expected_close: string) -> [..] *XML_Node {
    children: [..] *XML_Node;
    while p.at < p.source.count && p.error.count == 0 {
        if starts(p, "<!--") {
            parse_comment(p);
            continue;
        }
        if starts(p, "</") {
            p.at += 2;
            close_name := read_name(p);
            skip_space(p);
            if !starts(p, ">") {
                fail(p, "expected `>` after closing tag");
                break;
            }
            p.at += 1;
            if expected_close.count == 0 {
                fail(p, tprint("unexpected closing tag </%>", close_name));
                break;
            }
            if close_name != expected_close fail(p, tprint("expected </%>, got </%>", expected_close, close_name));
            return children;
        }
        if starts(p, "<") {
            child := parse_element(p);
            if child array_add(*children, child);
            continue;
        }
        if p.source[p.at] == #char "{" {
            child := parse_hole(p);
            if child array_add(*children, child);
            continue;
        }

        start := p.at;
        while p.at < p.source.count && p.source[p.at] != #char "<" && p.source[p.at] != #char "{" p.at += 1;
        if p.at == start {
            fail(p, "could not advance while parsing XML");
            break;
        }
        child := New(XML_Node);
        child.kind = .TEXT;
        child.text = decode_entities(p, slice(p.source, start, p.at - start));
        array_add(*children, child);
    }

    if expected_close.count && p.error.count == 0 fail(p, tprint("unclosed element <%>", expected_close));
    return children;
}

#scope_module
