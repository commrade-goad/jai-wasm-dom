#import "Basic";
#import "Compiler";
File :: #import "File";
Template :: #import "Template";

// Build-time helper: compiles a Jai program to `<output_name>.wasm` (wasm64).
// Use it from a small build script next to your program:
//
//     #import "Web_Build";
//     #run build_wasm("main", "main.jai", .["view.jaix"], #filepath);
//
// then run it with `jaic build.jai -import_dir <path to jaidom>/modules`.
// Needs lld 20+ (set JAIC_WASM_LD to its wasm-ld).
//
// `jaix` lists template files compiled to Jai and added to the program.
// `dir` is where `source` and the jaix files live and where the .wasm is
// written; `#filepath` in the build script means "next to this script".
// Programs meant for a Web Worker are built the same way, one call each.
build_wasm :: (output_name: string, source: string, jaix: [] string = .[], dir: string = "") {
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
    if dir.count options.output_path = dir;
    options.llvm_options.target_system_triple = "wasm64-unknown-unknown";
    options.llvm_options.target_system_features = "+bulk-memory,+sign-ext";
    options.additional_linker_arguments = .["-z", "stack-size=1048576"];

    for jaix add_jaix(tprint("%%", dir, it), workspace);
    set_build_options(options, workspace);

    add_build_file(tprint("%%", dir, source), workspace);
}

#scope_file

add_jaix :: (source_path: string, w: Workspace) {
    source, ok := File.read_entire_file(source_path);
    assert(ok, tprint("could not read jaix source: %", source_path));
    transformed := Template.compile_jaix_to_jai(source, source_path);
    free(source);
    assert(transformed.error.count == 0, transformed.error);
    add_build_string(transformed.jai, w);
}
