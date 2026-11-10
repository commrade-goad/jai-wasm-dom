#import "Basic";

DOM_Node :: #type,distinct s32;
DOM_NULL :: cast(DOM_Node) 0;
// Jai-callable callback. The host stores its WASM table index and asks the
// exported Jai dispatcher to invoke it with the persistent runtime context.
DOM_Event_Handler :: #type (element: DOM_Node, data: *void);

DOM_Props :: struct {
    id: string;
    class: string;
    title: string;
    role: string;
    text: string;
    onclick: DOM_Event_Handler;
}

// Host-side operations use integer handles so Jai can build and manipulate a
// normal node tree without depending on JavaScript object layout.
js_dom_find :: (selector: *u8, length: s64) -> DOM_Node #foreign;
js_dom_find_in :: (parent: DOM_Node, selector: *u8, length: s64) -> DOM_Node #foreign;
js_dom_create :: (tag: *u8, length: s64) -> DOM_Node #foreign;
js_dom_insert :: (parent: DOM_Node, child: DOM_Node, before: DOM_Node) #foreign;
js_dom_remove :: (element: DOM_Node) -> s32 #foreign;
js_dom_set_text :: (element: DOM_Node, text: *u8, length: s64) #foreign;
js_dom_get_value :: (element: DOM_Node, output: *u8, capacity: s64) -> s64 #foreign;
js_dom_set_value :: (element: DOM_Node, value: *u8, length: s64) #foreign;
js_dom_set_attribute :: (element: DOM_Node, name: *u8, name_length: s64, value: *u8, value_length: s64) #foreign;
js_dom_get_attribute :: (element: DOM_Node, name: *u8, name_length: s64, output: *u8, capacity: s64) -> s64 #foreign;
js_dom_remove_attribute :: (element: DOM_Node, name: *u8, name_length: s64) -> s32 #foreign;
js_dom_set_style :: (element: DOM_Node, name: *u8, name_length: s64, value: *u8, value_length: s64) #foreign;
js_dom_add_event_listener :: (element: DOM_Node, event_name: *u8, event_name_length: s64, callback: DOM_Event_Handler, data: *void) #foreign;

dom_find :: (selector: string) -> DOM_Node #no_context {
    return js_dom_find(selector.data, selector.count);
}

dom_find_in :: (parent: DOM_Node, selector: string) -> DOM_Node #no_context {
    return js_dom_find_in(parent, selector.data, selector.count);
}

dom_create :: (tag: string, props: DOM_Props = .{}) -> DOM_Node #no_context {
    element := js_dom_create(tag.data, tag.count);
    if props.id.count dom_set_attribute(element, "id", props.id);
    if props.class.count dom_set_attribute(element, "class", props.class);
    if props.title.count dom_set_attribute(element, "title", props.title);
    if props.role.count dom_set_attribute(element, "role", props.role);
    if props.text.count dom_text(element, props.text);
    if props.onclick dom_on(element, "click", props.onclick);
    return element;
}

dom_insert :: (parent: DOM_Node, child: DOM_Node, before: DOM_Node = 0) #no_context {
    js_dom_insert(parent, child, before);
}

dom_delete :: (element: DOM_Node) -> bool #no_context {
    return js_dom_remove(element) != 0;
}

dom_text :: (element: DOM_Node, text: string) #no_context {
    js_dom_set_text(element, text.data, text.count);
}

// Copy a form control's current value to a byte buffer. Returns -1 when the
// element has no value property, or the required byte count if capacity is too small.
dom_get_value :: (element: DOM_Node, output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_value(element, output, capacity);
}

dom_set_value :: (element: DOM_Node, value: string) #no_context {
    js_dom_set_value(element, value.data, value.count);
}

dom_set_attribute :: (element: DOM_Node, name: string, value: string) #no_context {
    js_dom_set_attribute(element, name.data, name.count, value.data, value.count);
}

// Returns the copied byte count, -1 when missing, or the required size when
// the caller's buffer is too small. Values are byte strings, not C strings.
dom_get_attribute :: (element: DOM_Node, name: string, output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_attribute(element, name.data, name.count, output, capacity);
}

dom_remove_attribute :: (element: DOM_Node, name: string) -> bool #no_context {
    return js_dom_remove_attribute(element, name.data, name.count) != 0;
}

dom_on :: (element: DOM_Node, event_name: string, callback: DOM_Event_Handler) #no_context {
    js_dom_add_event_listener(element, event_name.data, event_name.count, callback, null);
}

dom_on :: (element: DOM_Node, event_name: string, callback: DOM_Event_Handler, data: *$T) #no_context {
    js_dom_add_event_listener(element, event_name.data, event_name.count, callback, cast(*void)data);
}

dom_style :: (element: DOM_Node, name: string, value: string) #no_context {
    js_dom_set_style(element, name.data, name.count, value.data, value.count);
}

// Template text holes can be strings, scalar Jai values, or child components.
dom_content :: inline (parent: DOM_Node, content: $T) #expand {
    #if T == DOM_Node dom_insert(parent, content);
    else #if T == string dom_text(parent, content);
    else dom_text(parent, tprint("%", content));
}
