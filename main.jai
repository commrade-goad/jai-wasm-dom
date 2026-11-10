#import "Basic";
#import "Dom";
Runtime :: #import "Runtime_Support";

wasm_context: *#Context;

Click_Data :: struct {
    count: s32;
}

ensure_wasm_context :: () -> bool #no_context {
    if !wasm_context wasm_context = Runtime.__jai_runtime_init(0, null);
    return wasm_context != null;
}

with_wasm_context :: (body: Code) #expand {
    if !ensure_wasm_context() return;
    push_context wasm_context.* {
        defer reset_temporary_storage();
        #insert body;
    }
}

button_clicked :: (element: DOM_Node, data: *void) {
    state := cast(*Click_Data) data;
    if state == null return;
    state.count += 1;
    dom_text(element, tprint("Clicked % times — callback ran in Jai", state.count));
    dom_set_attribute(element, "data-clicked", tprint("%", state.count));
}

name_changed :: (input: DOM_Node, data: *void) {
    value_buffer: [512] u8;
    value_length := dom_get_value(input, *value_buffer[0], 512);
    preview := dom_find("#name-preview");
    if preview == DOM_NULL return;

    if value_length < 0 {
        dom_text(preview, "This element has no value property.");
        return;
    }
    if value_length > 512 {
        dom_text(preview, "Input is too long to copy into the demo buffer.");
        return;
    }

    dom_text(preview, string.{ value_length, *value_buffer[0] });
}

#program_export "jai_dom_event_dispatch"
jai_dom_event_dispatch :: (callback: DOM_Event_Handler, element: DOM_Node, data: *void) #c_call #no_context {
    with_wasm_context(#code {
        callback(element, data);
    });
}

#program_export "app_init"
app_init :: () #c_call #no_context {
    with_wasm_context(#code {
        click_data := Click_Data.{};
        main := dom_find("#main");
        if main == DOM_NULL return;

        existing := dom_find_in(main, "#existing");
        if existing != DOM_NULL {
            dom_text(existing, "This existing node was found and edited by Jai.");
            dom_set_attribute(existing, "data-edited", "true");
        }

        card := DemoCard(4, true);
        dom_style(card, "padding", "1.25rem");
        dom_style(card, "marginTop", "1rem");
        dom_style(card, "backgroundColor", "#f4f6fa");
        dom_insert(main, card);

        name_input := dom_find_in(card, "#name-input");
        if name_input != DOM_NULL {
            dom_on(name_input, "input", name_changed);
            dom_set_value(name_input, "Type something...");
            preview := dom_find_in(card, "#name-preview");
            if preview != DOM_NULL dom_text(preview, "Type something...");
        }

        jai_button := dom_find_in(card, "#jai-button");
        if jai_button != DOM_NULL dom_on(jai_button, "click", button_clicked, *click_data);

        dom_set_attribute(card, "data-state", "ready");
        value_buffer: [32] u8;
        attribute_size := dom_get_attribute(card, "data-state", *value_buffer[0], 32);
        if attribute_size > 0 dom_text(existing, "Attribute CRUD: data-state was read successfully.");
        dom_remove_attribute(card, "data-state");

        disposable := dom_find("#remove-me");
        if disposable != DOM_NULL dom_delete(disposable);
    });
}

