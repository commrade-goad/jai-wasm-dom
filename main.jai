#import "Basic";
#import "Dom";

button_clicked :: (element: DOM_Node) #c_call #no_context {
    dom_text(element, "Clicked — callback ran in Jai");
    dom_set_attribute(element, "data-clicked", "true");
}

#program_export "app_init"
app_init :: () #c_call #no_context {
    main := dom_find("#main");
    if main == 0 return;

    // Existing nodes can be queried and edited without assuming a fixed root.
    existing := dom_find_in(main, "#existing");
    if existing != 0 {
        dom_text(existing, "This existing node was found and edited by Jai.");
        dom_set_attribute(existing, "data-edited", "true");
    }

    card := dom_create("section", .{ class = "jai-card", role = "region" });
    dom_style(card, "padding", "1.25rem");
    dom_style(card, "marginTop", "1rem");
    dom_style(card, "backgroundColor", "#f4f6fa");

    heading := dom_create("h1");
    dom_text(heading, "Jai-built DOM tree");
    dom_insert(card, heading);

    description := dom_create("p");
    dom_text(description, "Find a target, create nodes, and insert them wherever you choose.");
    dom_insert(card, description);

    list := dom_create("ul");
    dom_insert(card, list);
    add_item :: (parent: DOM_Node, text: string) #expand #no_context {
        item := dom_create("li");
        dom_text(item, text);
        dom_insert(parent, item);
    }
    add_item(list, "dom_find(selector)");
    add_item(list, "dom_create(tag)");
    add_item(list, "dom_insert(parent, child)");

    button := dom_create("button", .{
        id = "jai-button",
        class = "jai-button",
        title = "Click to call a Jai function",
        text = "Click me",
        onclick = button_clicked,
    });
    dom_style(button, "padding", "0.6rem 1rem");
    dom_style(button, "cursor", "pointer");
    dom_insert(card, button);

    dom_insert(main, card);

    // Arbitrary attributes remain fully mutable after creation.
    dom_set_attribute(card, "data-state", "ready");
    value_buffer: [32] u8;
    attribute_size := dom_get_attribute(card, "data-state", *value_buffer[0], 32);
    if attribute_size > 0 dom_text(description, "Attribute CRUD: data-state was read successfully.");
    dom_remove_attribute(card, "data-state");

    // Delete a different existing node to show that the selected target and
    // the nodes being modified are independent.
    disposable := dom_find("#remove-me");
    if disposable != 0 dom_delete(disposable);
}

main :: () {}
