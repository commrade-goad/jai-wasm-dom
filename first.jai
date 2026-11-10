#import "Basic";
#import "Compiler";
File :: #import "File";
Template :: #import "Template";

#run {
    set_build_options_dc(.{ do_output = false });

    workspace := compiler_create_workspace("spa");
    options := get_build_options(workspace);
    copy_commonly_propagated_fields(get_build_options(), *options);

    options.output_type = .EXECUTABLE;
    options.backend = .LLVM;
    options.os_target = .WASM;
    options.cpu_target = .CUSTOM;
    options.emit_debug_info = .NONE;
    options.output_executable_name = "main";
    options.llvm_options.target_system_triple = "wasm64-unknown-unknown";
    options.llvm_options.target_system_features = "+bulk-memory,+sign-ext";
    options.additional_linker_arguments = .["-z", "stack-size=1048576"];

    set_build_options(options, workspace);

    source_path := tprint("%main.jaix", #filepath);
    source, ok := File.read_entire_file(source_path);
    assert(ok, tprint("could not read jaix source: %", source_path));
    transformed := Template.compile_jaix_to_jai(source);
    free(source);
    assert(transformed.error.count == 0, transformed.error);
    add_build_string(transformed.jai, workspace);
}
