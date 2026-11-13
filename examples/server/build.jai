// Native build: `jaic build.jai -import_dir <repo>/modules` writes ./server.
#import "Basic";
#import "Compiler";

build_server :: () {
    set_build_options_dc(.{ do_output = false });

    workspace := compiler_create_workspace("server");
    options := get_build_options(workspace);
    copy_commonly_propagated_fields(get_build_options(), *options);

    options.output_type = .EXECUTABLE;
    options.output_executable_name = "server";
    options.output_path = #filepath;
    set_build_options(options, workspace);

    add_build_file(tprint("%main.jai", #filepath), workspace);
}

#run build_server();
