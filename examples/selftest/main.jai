// Browser self-test for the Web module. Open index.html?selftest while
// test/server.py runs (or just: python3 test/run.py).
#import "Basic";
#import "String";
#import "Web";
#load "selftest.jai";

app_main :: () {
    selftest_flag, run_selftest := dom_read_param("selftest");
    if run_selftest async_selftest();
}

#program_export "app_init"
app_init :: () #c_call #no_context { with_wasm_context(#code { app_main(); }); }
