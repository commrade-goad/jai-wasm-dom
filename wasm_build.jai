#import "Basic";
#import "Compiler";
File :: #import "File";
Template :: #import "Template";

DEBUG :: false;

add_jaix :: (name: string, w: Workspace) {
    source_path := tprint("%%", #filepath, name);
    source, ok := File.read_entire_file(source_path);
    assert(ok, tprint("could not read jaix source: %", source_path));
    transformed := Template.compile_jaix_to_jai(source, source_path);
    free(source);
    assert(transformed.error.count == 0, transformed.error);
    if DEBUG {
        output_path := tprint("%.jai", source_path);
        File.write_entire_file(output_path, transformed.jai);
        add_build_file(output_path, w);
    } else {
        add_build_string(transformed.jai, w);
    }
}

// Builds `<output_name>.wasm` (wasm64) from `source`. Shared by the page
// (first.jai) and by every Jai worker (worker_first.jai).
build_wasm :: (output_name: string, source: string, jaix: string = "") {
    set_build_options_dc(.{ do_output = false });

    workspace := compiler_create_workspace(output_name);
    options := get_build_options(workspace);
    copy_commonly_propagated_fields(get_build_options(), *options);

    options.output_type = .EXECUTABLE;
    options.backend = .LLVM;
    options.os_target = .WASM;
    options.cpu_target = .CUSTOM;
    options.emit_debug_info = .NONE;
    options.output_executable_name = output_name;
    options.llvm_options.target_system_triple = "wasm64-unknown-unknown";
    options.llvm_options.target_system_features = "+bulk-memory,+sign-ext";
    options.additional_linker_arguments = .["-z", "stack-size=1048576"];

    if jaix.count add_jaix(jaix, workspace);
    set_build_options(options, workspace);

    add_build_file(source, workspace);
}
