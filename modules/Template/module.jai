#import "Basic";
#import "String";
XML :: #import "XML";

Template_Result :: struct {
    jai: string;
    error: string;
}

// Converts a .jaix file into ordinary Jai source. A template function's
// signature is retained and receives an inferred DOM_Node return type.
compile_jaix_to_jai :: (source: string) -> Template_Result {
    result: Template_Result;
    output: String_Builder;
    copied_until: s64;
    search_from: s64;

    while search_from < source.count {
        marker_start, marker_end := next_template_marker(source, search_from);
        if marker_start < 0 break;

        declaration_start := marker_end;
        while declaration_start < source.count && (source[declaration_start] == #char "\r" || source[declaration_start] == #char "\n" || source[declaration_start] == #char " " || source[declaration_start] == #char "\t") declaration_start += 1;

        body_open := find_function_body_open(source, declaration_start);
        if body_open < 0 {
            result.error = "#template must precede a Jai procedure declaration";
            return result;
        }
        body_close := find_matching_brace(source, body_open);
        if body_close < 0 {
            result.error = "unclosed #template function body";
            return result;
        }

        header := trim(slice(source, declaration_start, body_open - declaration_start));
        if find_index_from_left(header, "::") < 0 {
            result.error = "#template must precede a named Jai procedure";
            return result;
        }

        xml_source := slice(source, body_open + 1, body_close - body_open - 1);
        parsed := XML.parse(xml_source);
        if parsed.error.count {
            result.error = tprint("XML/template parse error at byte %: %", parsed.error_offset, parsed.error);
            return result;
        }

        generator: Generator;
        generator.next_node = 0;
        root_count := 0;
        root_node: string;
        for parsed.roots {
            if it.kind == .TEXT && trim(it.text).count == 0 continue;
            if it.kind != .ELEMENT {
                result.error = "a template function must have one root element";
                return result;
            }
            root_count += 1;
            if root_count > 1 {
                result.error = "a template function must have exactly one root element";
                return result;
            }
            root_node = emit_node(*generator, it, "", true);
        }
        if root_count != 1 {
            result.error = "a template function must have exactly one root element";
            return result;
        }
        if generator.error.count {
            result.error = generator.error;
            return result;
        }

        append(*output, slice(source, copied_until, marker_start - copied_until));
        if find_index_from_left(header, "->") < 0 header = tprint("% -> DOM_Node", header);
        print_to_builder(*output, "% {\n", header);
        append(*output, builder_to_string(*generator.body,, temp));
        print_to_builder(*output, "    return %;\n}\n", root_node);

        copied_until = body_close + 1;
        search_from = copied_until;
    }

    append(*output, slice(source, copied_until, source.count - copied_until));
    result.jai = builder_to_string(*output,, temp);
    return result;
}

#scope_file

Generator :: struct {
    body: String_Builder;
    next_node: s64;
    literal_index: s64;
    error: string;
}

is_space :: (c: u8) -> bool #no_context {
    return c == #char " " || c == #char "\t" || c == #char "\r" || c == #char "\n";
}

next_template_marker :: (source: string, from: s64) -> (start: s64, after: s64) {
    line_start := from;
    while line_start < source.count {
        line_end := line_start;
        while line_end < source.count && source[line_end] != #char "\n" line_end += 1;
        if trim(slice(source, line_start, line_end - line_start)) == "#template" {
            return line_start, ifx line_end < source.count then line_end + 1 else line_end;
        }
        line_start = line_end + 1;
    }
    return -1, -1;
}

find_function_body_open :: (source: string, start: s64) -> s64 #no_context {
    parentheses: s64;
    brackets: s64;
    quote: u8;
    escaped := false;
    i := start;
    while i < source.count {
        c := source[i];
        if quote != 0 {
            if escaped escaped = false;
            else if c == #char "\\" escaped = true;
            else if c == quote quote = 0;
        } else if c == #char "\"" quote = c;
        else if c == #char "(" parentheses += 1;
        else if c == #char ")" parentheses -= 1;
        else if c == #char "[" brackets += 1;
        else if c == #char "]" brackets -= 1;
        else if c == #char "{" && parentheses == 0 && brackets == 0 return i;
        i += 1;
    }
    return -1;
}

find_matching_brace :: (source: string, open: s64) -> s64 #no_context {
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
        } else if block_comment {
            if c == #char "*" && next == #char "/" {
                block_comment = false;
                i += 1;
            }
        } else if quote != 0 {
            if escaped escaped = false;
            else if c == #char "\\" escaped = true;
            else if c == quote quote = 0;
        } else if c == #char "\"" quote = c;
        else if c == #char "/" && next == #char "/" {
            line_comment = true;
            i += 1;
        } else if c == #char "/" && next == #char "*" {
            block_comment = true;
            i += 1;
        } else if c == #char "{" depth += 1;
        else if c == #char "}" {
            depth -= 1;
            if depth == 0 return i;
        }
        i += 1;
    }
    return -1;
}

quoted :: (text: string) -> string {
    builder: String_Builder;
    append(*builder, #char "\"");
    for c: text {
        if c == #char "\"" append(*builder, "\\\"");
        else if c == #char "\\" append(*builder, "\\\\");
        else if c == #char "\n" append(*builder, "\\n");
        else if c == #char "\r" append(*builder, "\\r");
        else if c == #char "\t" append(*builder, "\\t");
        else if c < 32 print_to_builder(*builder, "\\x%", formatInt(c, base = 16, minimum_digits = 2));
        else append(*builder, c);
    }
    append(*builder, #char "\"");
    return builder_to_string(*builder,, temp);
}

emit_node :: (g: *Generator, node: *XML.XML_Node, parent: string, is_root := false) -> string {
    if node.kind == .TEXT {
        if trim(node.text).count == 0 return "";
        if !parent.count {
            g.error = "text is not allowed outside the template root element";
            return "";
        }
        print_to_builder(*g.body, "    dom_text(%, %);\n", parent, quoted(node.text));
        return "";
    }

    if node.kind == .JAI_HOLE {
        if !parent.count {
            g.error = "a Jai hole is not allowed outside the template root element";
            return "";
        }
        emit_hole(g, node.text, parent);
        return "";
    }

    id := g.next_node;
    g.next_node += 1;
    variable := tprint("template_node_%", id);
    print_to_builder(*g.body, "    % := dom_create(%);\n", variable, quoted(node.name));
    if parent.count print_to_builder(*g.body, "    dom_insert(%, %);\n", parent, variable);

    for attribute: node.attributes emit_attribute(g, variable, attribute.name, attribute.value);
    for child: node.children emit_node(g, child, variable);

    return variable;
}

emit_attribute :: (g: *Generator, element: string, name: string, value: string) {
    if starts_with_hole(value) {
        expression := trim(slice(value, 1, value.count - 2));
        event_name := event_from_attribute(name);
        if event_name.count {
            print_to_builder(*g.body, "    dom_on(%, %, %);\n", element, quoted(event_name), expression);
        } else {
            print_to_builder(*g.body, "    dom_set_attribute(%, %, tprint(\"%\", %));\n", element, quoted(name), "%", expression);
        }
        return;
    }

    if name.count >= 2 && slice(name, 0, 2) == "on" {
        g.error = tprint("event attribute `%` must use a Jai value hole, such as `%={handler}", name, name);
        return;
    }
    print_to_builder(*g.body, "    dom_set_attribute(%, %, %);\n", element, quoted(name), quoted(value));
}

starts_with_hole :: (value: string) -> bool #no_context {
    return value.count >= 2 && value[0] == #char "{" && value[value.count - 1] == #char "}";
}

event_from_attribute :: (name: string) -> string {
    if name.count < 3 || slice(name, 0, 2) != "on" return "";
    event := slice(name, 2, name.count - 2);
    return lowercase(event);
}

lowercase :: (text: string) -> string {
    result := copy_temporary_string(text);
    for *result if it.* >= #char "A" && it.* <= #char "Z" it.* += #char "a" - #char "A";
    return result;
}

emit_hole :: (g: *Generator, source: string, parent: string) {
    code := trim(source);
    if is_block_header(code) {
        emit_control(g, code, parent);
        return;
    }
    if has_statement_terminator(code) {
        print_to_builder(*g.body, "    %\n", code);
        return;
    }
    print_to_builder(*g.body, "    dom_content(%, (%));\n", parent, code);
}

is_block_header :: (code: string) -> bool {
    return begins_word(code, "if") || begins_word(code, "for") || begins_word(code, "while") ||
        begins_word(code, "defer") || begins_word(code, "push_context") ||
        begins_word(code, "using") || begins_word(code, "#if") || begins_word(code, "#run");
}

has_statement_terminator :: (code: string) -> bool #no_context {
    quote: u8;
    escaped := false;
    parentheses: s64;
    brackets: s64;
    braces: s64;
    i: s64;
    while i < code.count {
        c := code[i];
        if quote != 0 {
            if escaped escaped = false;
            else if c == #char "\\" escaped = true;
            else if c == quote quote = 0;
        } else if c == #char "\"" quote = c;
        else if c == #char "(" parentheses += 1;
        else if c == #char ")" parentheses -= 1;
        else if c == #char "[" brackets += 1;
        else if c == #char "]" brackets -= 1;
        else if c == #char "{" braces += 1;
        else if c == #char "}" braces -= 1;
        else if c == #char ";" && parentheses == 0 && brackets == 0 && braces == 0 return true;
        i += 1;
    }
    return false;
}

begins_word :: (source: string, word: string) -> bool {
    return source.count > word.count && slice(source, 0, word.count) == word && is_space(source[word.count]);
}

control_open :: (source: string, from: s64) -> s64 #no_context {
    quote: u8;
    escaped := false;
    parentheses: s64;
    brackets: s64;
    i := from;
    while i < source.count {
        c := source[i];
        if quote != 0 {
            if escaped escaped = false;
            else if c == #char "\\" escaped = true;
            else if c == quote quote = 0;
        } else if c == #char "\"" quote = c;
        else if c == #char "(" parentheses += 1;
        else if c == #char ")" parentheses -= 1;
        else if c == #char "[" brackets += 1;
        else if c == #char "]" brackets -= 1;
        else if c == #char "{" && parentheses == 0 && brackets == 0 return i;
        i += 1;
    }
    return -1;
}

emit_control :: (g: *Generator, code: string, parent: string) {
    open := control_open(code, 0);
    if open < 0 {
        g.error = tprint("Jai control block is missing its body: %", code);
        return;
    }
    close := find_matching_brace(code, open);
    if close < 0 {
        g.error = tprint("unclosed Jai control block: %", code);
        return;
    }

    header := trim(slice(code, 0, open));
    if is_block_header(header) {
        print_to_builder(*g.body, "    % {\n", header);
        body := slice(code, open + 1, close - open - 1);
        if !emit_control_body(g, body, parent) return;
        print_to_builder(*g.body, "    }\n");
    } else {
        g.error = tprint("unsupported template control header `%`", header);
        return;
    }

    remainder := trim(slice(code, close + 1, code.count - close - 1));
    if remainder.count == 0 return;
    if !begins_word(remainder, "else") {
        g.error = tprint("unexpected code after template control block: %", remainder);
        return;
    }

    after_else := trim(slice(remainder, 4, remainder.count - 4));
    if after_else.count == 0 {
        g.error = "else must be followed by a Jai block";
        return;
    }
    if begins_word(after_else, "if") {
        print_to_builder(*g.body, "    else ");
        emit_control(g, after_else, parent);
        return;
    }

    else_open := control_open(after_else, 0);
    if else_open < 0 || trim(slice(after_else, 0, else_open)).count != 0 {
        g.error = "else must be followed by `{ ... }`";
        return;
    }
    else_close := find_matching_brace(after_else, else_open);
    if else_close < 0 || trim(slice(after_else, else_close + 1, after_else.count - else_close - 1)).count {
        g.error = "malformed else block";
        return;
    }
    print_to_builder(*g.body, "    else {\n");
    if !emit_control_body(g, slice(after_else, else_open + 1, else_close - else_open - 1), parent) return;
    print_to_builder(*g.body, "    }\n");
}

emit_control_body :: (g: *Generator, source: string, parent: string) -> bool {
    parsed := XML.parse(source);
    if parsed.error.count {
        g.error = tprint("XML in Jai control block at byte %: %", parsed.error_offset, parsed.error);
        return false;
    }
    for parsed.roots {
        if it.kind == .TEXT {
            append(*g.body, it.text);
        } else {
            emit_node(g, it, parent);
        }
    }
    return g.error.count == 0;
}

#scope_module
