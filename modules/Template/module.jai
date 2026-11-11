#import "Basic";
#import "String";
XML :: #import "XML";

Template_Result :: struct {
    jai: string;
    error: string;
    error_offset: s64;
}

// Converts a .jaix file into ordinary Jai source. A template function's
// signature is retained and receives an inferred DOM_Node return type.
compile_jaix_to_jai :: (source: string, filename: string = "<template>") -> Template_Result {
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
            return template_error(filename, source, marker_start, "#template must precede a Jai procedure declaration");
        }
        body_close := find_matching_brace(source, body_open);
        if body_close < 0 {
            return template_error(filename, source, body_open, "unclosed #template function body");
        }

        header := trim(slice(source, declaration_start, body_open - declaration_start));
        if find_index_from_left(header, "::") < 0 {
            return template_error(filename, source, declaration_start, "#template must precede a named Jai procedure");
        }

        xml_source := slice(source, body_open + 1, body_close - body_open - 1);
        xml_offset := body_open + 1;
        parsed := XML.parse(xml_source);
        if parsed.error.count {
            return template_error(filename, source, xml_offset + parsed.error_offset, tprint("template parse error: %", parsed.error));
        }
        offset_nodes(parsed.roots, xml_offset);

        generator: Generator;
        generator.next_node = 0;
        root_count := 0;
        root_node: string;
        for root: parsed.roots {
            if root.kind == .TEXT && trim(root.text).count == 0 continue;
            if root.kind != .ELEMENT {
                return template_error(filename, source, root.offset, "a template function must have one root element");
            }
            root_count += 1;
            if root_count > 1 {
                return template_error(filename, source, root.offset, "a template function must have exactly one root element");
            }
            root_node = emit_node(*generator, root, "", true);
        }
        if root_count != 1 {
            return template_error(filename, source, xml_offset, "a template function must have exactly one root element");
        }
        if generator.error.count {
            return template_error(filename, source, generator.error_offset, generator.error);
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
    error_offset: s64;
}

template_error :: (filename: string, source: string, offset: s64, message: string) -> Template_Result {
    result: Template_Result;
    result.error_offset = offset;
    result.error = format_error(filename, source, offset, message);
    return result;
}

// Formats an error as `path:line:column: message`, which most editors and
// terminals turn into a jumpable location.
format_error :: (filename: string, source: string, offset: s64, message: string) -> string {
    line, column := line_and_column(source, offset);
    if filename.count == 0 return tprint("%:%: %", line, column, message);
    return tprint("%:%:%: %", filename, line, column, message);
}

line_and_column :: (source: string, offset: s64) -> (line: s64, column: s64) #no_context {
    line = 1;
    column = 1;
    limit := offset;
    if limit < 0 limit = 0;
    if limit > source.count limit = source.count;
    i: s64;
    while i < limit {
        if source[i] == #char "\n" {
            line += 1;
            column = 1;
        } else column += 1;
        i += 1;
    }
    return line, column;
}

// The XML parser records offsets relative to the fragment it was given. Shift
// every node so nested control-block fragments still point into the .jaix file.
offset_nodes :: (nodes: [] *XML.XML_Node, delta: s64) {
    for node: nodes {
        node.offset += delta;
        for *attribute: node.attributes attribute.offset += delta;
        offset_nodes(node.children, delta);
    }
}

leading_space_count :: (text: string) -> s64 #no_context {
    i: s64;
    while i < text.count && is_space(text[i]) i += 1;
    return i;
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
            g.error_offset = node.offset;
            return "";
        }
        print_to_builder(*g.body, "    dom_text(%, %);\n", parent, quoted(node.text));
        return "";
    }

    if node.kind == .JAI_HOLE {
        if !parent.count {
            g.error = "a Jai hole is not allowed outside the template root element";
            g.error_offset = node.offset;
            return "";
        }
        emit_hole(g, node, parent);
        return "";
    }

    id := g.next_node;
    g.next_node += 1;
    variable := tprint("template_node_%", id);
    print_to_builder(*g.body, "    % := dom_create(%);\n", variable, quoted(node.name));
    if parent.count print_to_builder(*g.body, "    dom_insert(%, %);\n", parent, variable);

    for attribute: node.attributes emit_attribute(g, variable, attribute);
    for child: node.children emit_node(g, child, variable);

    return variable;
}

emit_attribute :: (g: *Generator, element: string, attribute: XML.XML_Attribute) {
    name := attribute.name;
    trimmed_value := trim(attribute.value);
    if starts_with_hole(trimmed_value) {
        expression := trim(slice(trimmed_value, 1, trimmed_value.count - 2));
        event_name := event_from_attribute(name);
        if event_name.count {
            print_to_builder(*g.body, "    dom_on(%, %, %);\n", element, quoted(event_name), expression);
        } else {
            print_to_builder(*g.body, "    dom_set_attribute_value(%, %, %);\n", element, quoted(name), expression);
        }
        return;
    }

    if name.count >= 2 && slice(name, 0, 2) == "on" {
        g.error = tprint("event attribute `%` must use a Jai value hole, such as `%={handler}", name, name);
        g.error_offset = attribute.offset;
        return;
    }
    print_to_builder(*g.body, "    dom_set_attribute(%, %, %);\n", element, quoted(name), quoted(attribute.value));
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

emit_hole :: (g: *Generator, node: *XML.XML_Node, parent: string) {
    code := trim(node.text);
    code_offset := node.offset + 1 + leading_space_count(node.text);
    if is_block_header(code) {
        emit_control(g, code, parent, code_offset);
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

emit_control :: (g: *Generator, code: string, parent: string, code_offset: s64) {
    open := control_open(code, 0);
    if open < 0 {
        g.error = tprint("Jai control block is missing its body: %", code);
        g.error_offset = code_offset;
        return;
    }
    close := find_matching_brace(code, open);
    if close < 0 {
        g.error = tprint("unclosed Jai control block: %", code);
        g.error_offset = code_offset;
        return;
    }

    header := trim(slice(code, 0, open));
    if is_block_header(header) {
        print_to_builder(*g.body, "    % {\n", header);
        body := slice(code, open + 1, close - open - 1);
        if !emit_control_body(g, body, parent, code_offset + open + 1) return;
        print_to_builder(*g.body, "    }\n");
    } else {
        g.error = tprint("unsupported template control header `%`", header);
        g.error_offset = code_offset;
        return;
    }

    remainder_raw := slice(code, close + 1, code.count - close - 1);
    remainder := trim(remainder_raw);
    if remainder.count == 0 return;
    remainder_offset := code_offset + close + 1 + leading_space_count(remainder_raw);
    if !begins_word(remainder, "else") {
        g.error = tprint("unexpected code after template control block: %", remainder);
        g.error_offset = remainder_offset;
        return;
    }

    after_else_raw := slice(remainder, 4, remainder.count - 4);
    after_else := trim(after_else_raw);
    after_else_offset := remainder_offset + 4 + leading_space_count(after_else_raw);
    if after_else.count == 0 {
        g.error = "else must be followed by a Jai block";
        g.error_offset = remainder_offset;
        return;
    }
    if begins_word(after_else, "if") {
        print_to_builder(*g.body, "    else ");
        emit_control(g, after_else, parent, after_else_offset);
        return;
    }

    else_open := control_open(after_else, 0);
    if else_open < 0 || trim(slice(after_else, 0, else_open)).count != 0 {
        g.error = "else must be followed by `{ ... }`";
        g.error_offset = after_else_offset;
        return;
    }
    else_close := find_matching_brace(after_else, else_open);
    if else_close < 0 || trim(slice(after_else, else_close + 1, after_else.count - else_close - 1)).count {
        g.error = "malformed else block";
        g.error_offset = after_else_offset;
        return;
    }
    print_to_builder(*g.body, "    else {\n");
    if !emit_control_body(g, slice(after_else, else_open + 1, else_close - else_open - 1), parent, after_else_offset + else_open + 1) return;
    print_to_builder(*g.body, "    }\n");
}

emit_control_body :: (g: *Generator, source: string, parent: string, source_offset: s64) -> bool {
    parsed := XML.parse(source);
    if parsed.error.count {
        g.error = tprint("XML in Jai control block: %", parsed.error);
        g.error_offset = source_offset + parsed.error_offset;
        return false;
    }
    offset_nodes(parsed.roots, source_offset);
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
