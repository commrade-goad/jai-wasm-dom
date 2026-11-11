#import "Basic";
#import "String";
#import "Dom";
#load "context.jai";

View :: enum {
    COUNTER;
    TODOS;
}

Todo_Filter :: enum {
    ALL;
    ACTIVE;
    DONE;
}

Counter_State :: struct {
    count: s32;
}

Todo_Item :: struct {
    id: s32;
    text: string;
    done: bool;
}

counter_state: Counter_State;
todos: [..] Todo_Item;
next_todo_id: s32;
current_view: View = .COUNTER;
current_filter: Todo_Filter = .ALL;

#program_export "jai_dom_event_dispatch"
jai_dom_event_dispatch :: (callback: DOM_Callback, element: DOM_Node, data: *void) #c_call #no_context {
    with_wasm_context(#code {
        callback(data);
    });
}

render_view :: () {
    view := dom_find("#view");
    if view == DOM_NULL return;

    dom_clear(view);

    if current_view == .TODOS render_todos(view);
    else render_counter(view);

    update_nav();
}

update_nav :: () {
    counter_nav := dom_find("#nav-counter");
    todos_nav := dom_find("#nav-todos");

    if counter_nav != DOM_NULL {
        if current_view == .COUNTER dom_set_attribute(counter_nav, "data-active", "true");
        else dom_remove_attribute(counter_nav, "data-active");
    }
    if todos_nav != DOM_NULL {
        if current_view == .TODOS dom_set_attribute(todos_nav, "data-active", "true");
        else dom_remove_attribute(todos_nav, "data-active");
    }
}

nav_counter_clicked :: (data: *void) {
    current_view = .COUNTER;
    render_view();
}

nav_todos_clicked :: (data: *void) {
    current_view = .TODOS;
    render_view();
}

// Counter

render_counter :: (view: DOM_Node) {
    panel := CounterView();
    dom_insert(view, panel);

    increment := dom_find_in(panel, "#counter-inc");
    if increment != DOM_NULL dom_on(increment, "click", counter_increment, *counter_state);

    decrement := dom_find_in(panel, "#counter-dec");
    if decrement != DOM_NULL dom_on(decrement, "click", counter_decrement, *counter_state);

    reset := dom_find_in(panel, "#counter-reset");
    if reset != DOM_NULL dom_on(reset, "click", counter_reset, *counter_state);

    update_counter_display();
}

update_counter_display :: () {
    value := dom_find("#counter-value");
    if value != DOM_NULL dom_text(value, tprint("%", counter_state.count));
}

counter_increment :: (data: *void) {
    state := cast(*Counter_State) data;
    if state == null return;
    state.count += 1;
    update_counter_display();
}

counter_decrement :: (data: *void) {
    state := cast(*Counter_State) data;
    if state == null return;
    state.count -= 1;
    update_counter_display();
}

counter_reset :: (data: *void) {
    state := cast(*Counter_State) data;
    if state == null return;
    state.count = 0;
    update_counter_display();
}

// Todos

render_todos :: (view: DOM_Node) {
    panel := TodosView();
    dom_insert(view, panel);
    render_todo_list(panel);
}

render_todo_list :: (panel: DOM_Node) {
    list := dom_find_in(panel, "#todo-list");
    if list == DOM_NULL return;

    dom_clear(list);
    update_filter_chips(panel);

    shown: s32;
    done_total: s32;

    for *todo: todos {
        if todo.done done_total += 1;

        if current_filter == .ACTIVE && todo.done continue;
        if current_filter == .DONE && !todo.done continue;

        render_todo_row(list, todo);
        shown += 1;
    }

    empty := dom_find_in(panel, "#todo-empty");
    if empty != DOM_NULL {
        if shown == 0 dom_style(empty, "display", "block");
        else dom_style(empty, "display", "none");
    }

    count := dom_find_in(panel, "#todo-count");
    if count != DOM_NULL dom_text(count, tprint("% of % done", done_total, todos.count));
}

update_filter_chips :: (panel: DOM_Node) {
    all := dom_find_in(panel, "#filter-all");
    active := dom_find_in(panel, "#filter-active");
    done := dom_find_in(panel, "#filter-done");

    if all != DOM_NULL {
        if current_filter == .ALL dom_set_attribute(all, "data-active", "true");
        else dom_remove_attribute(all, "data-active");
    }
    if active != DOM_NULL {
        if current_filter == .ACTIVE dom_set_attribute(active, "data-active", "true");
        else dom_remove_attribute(active, "data-active");
    }
    if done != DOM_NULL {
        if current_filter == .DONE dom_set_attribute(done, "data-active", "true");
        else dom_remove_attribute(done, "data-active");
    }
}

render_todo_row :: (list: DOM_Node, todo: *Todo_Item) {
    row := TodoRow(todo.id, todo.text, todo.done);
    dom_insert(list, row);

    toggle := dom_find_in(row, ".todo-toggle");
    if toggle != DOM_NULL dom_on(toggle, "click", todo_toggle_clicked, todo);

    remove_button := dom_find_in(row, ".todo-delete");
    if remove_button != DOM_NULL dom_on(remove_button, "click", todo_delete_clicked, todo);
}

todo_add_clicked :: (data: *void) {
    input := dom_find("#todo-input");
    if input == DOM_NULL return;

    value, ok := dom_read_value(input);
    if !ok return;

    trimmed := trim(value);
    if trimmed.count == 0 {
        if value.count > 0 free(value);
        return;
    }

    text := copy_string(trimmed);
    if value.count > 0 free(value);

    array_add(*todos, Todo_Item.{ id = next_todo_id, text = text, done = false });
    next_todo_id += 1;

    dom_set_value(input, "");
    render_view();
}

todo_toggle_clicked :: (data: *void) {
    todo := cast(*Todo_Item) data;
    if todo == null return;
    todo.done = !todo.done;
    render_view();
}

todo_delete_clicked :: (data: *void) {
    todo := cast(*Todo_Item) data;
    if todo == null return;

    id := todo.id;
    for candidate, i: todos {
        if candidate.id == id {
            if todos[i].text.count > 0 free(todos[i].text);
            array_ordered_remove_by_index(*todos, i);
            break;
        }
    }
    render_view();
}

filter_all_clicked :: (data: *void) {
    current_filter = .ALL;
    render_view();
}

filter_active_clicked :: (data: *void) {
    current_filter = .ACTIVE;
    render_view();
}

filter_done_clicked :: (data: *void) {
    current_filter = .DONE;
    render_view();
}

#program_export "app_init"
app_init :: () #c_call #no_context {
    with_wasm_context(#code {
        main := dom_find("#main");
        if main == DOM_NULL return;

        shell := AppShell();
        dom_insert(main, shell);

        nav_counter := dom_find_in(shell, "#nav-counter");
        if nav_counter != DOM_NULL dom_on(nav_counter, "click", nav_counter_clicked);

        nav_todos := dom_find_in(shell, "#nav-todos");
        if nav_todos != DOM_NULL dom_on(nav_todos, "click", nav_todos_clicked);

        render_view();
    });
}
