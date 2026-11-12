#import "Basic";

DOM_Node :: #type,distinct s32;
DOM_NULL :: cast(DOM_Node) 0;
// Jai-callable callback. The host stores its WASM table index and asks the
// exported Jai dispatcher to invoke it with the persistent runtime context.
DOM_Event_Handler :: #type (element: DOM_Node, data: *void);
DOM_Callback :: #type (data: *void);

DOM_Props :: struct {
    id: string;
    class: string;
    title: string;
    role: string;
    text: string;
    onclick: DOM_Callback;
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
js_dom_add_event_listener :: (element: DOM_Node, event_name: *u8, event_name_length: s64, callback: DOM_Callback, data: *void) #foreign;
js_dom_add_window_event_listener :: (event_name: *u8, event_name_length: s64, callback: DOM_Callback, data: *void) #foreign;
js_dom_clear :: (element: DOM_Node) #foreign;

// Current-event access. Only valid while an event handler is running.
js_event_prevent_default :: () #foreign;
js_event_key_length :: () -> s64 #foreign;
js_event_key_read :: (output: *u8, capacity: s64) -> s64 #foreign;

// localStorage. Missing keys report -1 from the length probe.
js_storage_length :: (key: *u8, key_length: s64) -> s64 #foreign;
js_storage_get :: (key: *u8, key_length: s64, output: *u8, capacity: s64) -> s64 #foreign;
js_storage_set :: (key: *u8, key_length: s64, value: *u8, value_length: s64) -> s32 #foreign;
js_storage_remove :: (key: *u8, key_length: s64) #foreign;

// URL / history bridge. Lets the app read and change the address bar without a
// page reload, which is what SPA routing needs.
js_dom_get_url :: (output: *u8, capacity: s64) -> s64 #foreign;
js_dom_set_url :: (url: *u8, length: s64, replace: s32) #foreign;
js_dom_get_path :: (output: *u8, capacity: s64) -> s64 #foreign;
js_dom_get_search :: (output: *u8, capacity: s64) -> s64 #foreign;
js_dom_get_hash :: (output: *u8, capacity: s64) -> s64 #foreign;
js_dom_get_param :: (name: *u8, name_length: s64, output: *u8, capacity: s64) -> s64 #foreign;
js_dom_set_param :: (name: *u8, name_length: s64, value: *u8, value_length: s64, replace: s32) #foreign;
js_dom_remove_param :: (name: *u8, name_length: s64, replace: s32) #foreign;

// Length probes. Ask the host how many bytes a value needs before allocating
// the destination, so Jai code never needs a fixed MAX_ buffer.
js_dom_value_length :: (element: DOM_Node) -> s64 #foreign;
js_dom_attribute_length :: (element: DOM_Node, name: *u8, name_length: s64) -> s64 #foreign;
js_dom_url_length :: () -> s64 #foreign;
js_dom_path_length :: () -> s64 #foreign;
js_dom_search_length :: () -> s64 #foreign;
js_dom_hash_length :: () -> s64 #foreign;
js_dom_param_length :: (name: *u8, name_length: s64) -> s64 #foreign;

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

// Attribute values from templates can be any Jai value. Strings are passed
// straight through; numbers, bools and other types are formatted in context.
dom_set_attribute_value :: inline (element: DOM_Node, name: string, value: $T) #expand {
    #if T == string dom_set_attribute(element, name, value);
    else dom_set_attribute(element, name, tprint("%", value));
}

// Returns the copied byte count, -1 when missing, or the required size when
// the caller's buffer is too small. Values are byte strings, not C strings.
dom_get_attribute :: (element: DOM_Node, name: string, output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_attribute(element, name.data, name.count, output, capacity);
}

dom_remove_attribute :: (element: DOM_Node, name: string) -> bool #no_context {
    return js_dom_remove_attribute(element, name.data, name.count) != 0;
}

dom_on :: (element: DOM_Node, event_name: string, callback: DOM_Callback) #no_context {
    js_dom_add_event_listener(element, event_name.data, event_name.count, callback, null);
}

dom_on :: (element: DOM_Node, event_name: string, callback: DOM_Callback, data: *$T) #no_context {
    js_dom_add_event_listener(element, event_name.data, event_name.count, callback, cast(*void)data);
}

// Window-level events such as "popstate" for SPA back/forward routing.
dom_on_window :: (event_name: string, callback: DOM_Callback, data: *void = null) #no_context {
    js_dom_add_window_event_listener(event_name.data, event_name.count, callback, data);
}

// Removes every child of an element, keeping the element itself in the tree.
dom_clear :: (element: DOM_Node) #no_context {
    js_dom_clear(element);
}

dom_style :: (element: DOM_Node, name: string, value: string) #no_context {
    js_dom_set_style(element, name.data, name.count, value.data, value.count);
}

// Full address bar URL, e.g. "https://host/app?tab=one#top".
dom_get_url :: (output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_url(output, capacity);
}

// Updates the address bar without reloading. `replace` swaps the current
// history entry instead of pushing a new one.
dom_set_url :: (url: string, replace: bool = false) #no_context {
    js_dom_set_url(url.data, url.count, cast(s32) ifx replace then 1 else 0);
}

// Path part, e.g. "/app".
dom_get_path :: (output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_path(output, capacity);
}

// Raw query string including the leading "?", e.g. "?tab=one".
dom_get_search :: (output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_search(output, capacity);
}

// Fragment including the leading "#".
dom_get_hash :: (output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_hash(output, capacity);
}

// Reads one query parameter. Returns -1 when missing, the copied byte count
// otherwise, or the required size when capacity is too small.
dom_get_param :: (name: string, output: *u8, capacity: s64) -> s64 #no_context {
    return js_dom_get_param(name.data, name.count, output, capacity);
}

// Adds or replaces a query parameter in the address bar without reloading.
dom_set_param :: (name: string, value: string, replace: bool = false) #no_context {
    js_dom_set_param(name.data, name.count, value.data, value.count, cast(s32) ifx replace then 1 else 0);
}

// Removes a query parameter from the address bar without reloading.
dom_remove_param :: (name: string, replace: bool = false) #no_context {
    js_dom_remove_param(name.data, name.count, cast(s32) ifx replace then 1 else 0);
}

// Context-allocated reads. The host reports the byte length first, then a
// String_Builder grows to exactly that size and the host fills it. These are not
// `#no_context`: the returned strings come from the context allocator, so the
// caller owns them and frees them with `free`.
dom_read_value :: (element: DOM_Node) -> (value: string, ok: bool) {
    length := js_dom_value_length(element);
    if length < 0 return "", false;
    if length == 0 return "", true;

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_value(element, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), true;
}

dom_read_attribute :: (element: DOM_Node, name: string) -> (value: string, ok: bool) {
    length := js_dom_attribute_length(element, name.data, name.count);
    if length < 0 return "", false;
    if length == 0 return "", true;

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_attribute(element, name.data, name.count, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), true;
}

dom_read_url :: () -> string {
    length := js_dom_url_length();
    if length <= 0 return "";

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_url(space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder);
}

dom_read_path :: () -> string {
    length := js_dom_path_length();
    if length <= 0 return "";

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_path(space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder);
}

dom_read_search :: () -> string {
    length := js_dom_search_length();
    if length <= 0 return "";

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_search(space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder);
}

dom_read_hash :: () -> string {
    length := js_dom_hash_length();
    if length <= 0 return "";

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_hash(space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder);
}

dom_read_param :: (name: string) -> (value: string, ok: bool) {
    length := js_dom_param_length(name.data, name.count);
    if length < 0 return "", false;
    if length == 0 return "", true;

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_dom_get_param(name.data, name.count, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), true;
}

// Template text holes can be strings, scalar Jai values, or child components.
dom_content :: inline (parent: DOM_Node, content: $T) #expand {
    #if T == DOM_Node dom_insert(parent, content);
    else #if T == string dom_text(parent, content);
    else dom_text(parent, tprint("%", content));
}

// Calls event.preventDefault() on the event being handled (form submit, link
// click, ...). Does nothing outside an event handler.
dom_event_prevent_default :: () #no_context {
    js_event_prevent_default();
}

// `event.key` of the keyboard event being handled. `ok` is false when the
// current event has no key. Context-allocated; the caller frees it.
dom_read_event_key :: () -> (value: string, ok: bool) {
    length := js_event_key_length();
    if length < 0 return "", false;
    if length == 0 return "", true;

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_event_key_read(space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), true;
}

// localStorage. `storage_set` returns false when the browser refuses (quota,
// private mode). `storage_read` is context-allocated; the caller frees it.
storage_set :: (key: string, value: string) -> bool #no_context {
    return js_storage_set(key.data, key.count, value.data, value.count) != 0;
}

storage_remove :: (key: string) #no_context {
    js_storage_remove(key.data, key.count);
}

storage_read :: (key: string) -> (value: string, ok: bool) {
    length := js_storage_length(key.data, key.count);
    if length < 0 return "", false;
    if length == 0 return "", true;

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_storage_get(key.data, key.count, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), true;
}
