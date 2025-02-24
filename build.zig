const std = @import("std");

const Build = std.Build;
const Step = std.Build.Step;

const LUAU_VERSION = std.SemanticVersion{ .major = 0, .minor = 655, .patch = 0 };
// const VERSION_HASH = "12202e48ce8bbddc043bbaadd10ac783d427b41b1ad9b6b3cb4b91bff6cdbb1a3d98";

pub fn build(b: *Build) !void {
    // Remove the default install and uninstall steps
    b.top_level_steps = .{};

    const luau_dep = b.lazyDependency("luau", .{}) orelse unreachable;

    // std.debug.assert(std.mem.eql(u8, luau_dep.builder.pkg_hash, VERSION_HASH));

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_4_vector = b.option(bool, "use_4_vector", "Build Luau to use 4-vectors instead of the default 3-vector.") orelse false;
    const wasm_env_name = b.option([]const u8, "wasm_env", "The environment to import symbols from when building for WebAssembly.") orelse "env";
    const shared_library = b.option(bool, "shared", "Build a shared library instead of a static library.") orelse false;

    // Expose build configuration to the zig-luau module
    const config = b.addOptions();
    config.addOption(bool, "use_4_vector", use_4_vector);
    config.addOption(std.SemanticVersion, "luau_version", LUAU_VERSION);

    const is_wasm = target.result.ofmt == .wasm;
    const codegen_supported = !is_wasm;

    // Luau C Headers
    const headers = b.addTranslateC(.{
        .root_source_file = b.path("src/luau.h"),
        .target = target,
        .optimize = optimize,
    });
    headers.addIncludePath(luau_dep.path("Compiler/include"));
    headers.addIncludePath(luau_dep.path("VM/include"));
    if (codegen_supported)
        headers.addIncludePath(luau_dep.path("CodeGen/include"));

    const c_module = headers.addModule("c_module");

    const lib = try buildLuau(b, target, luau_dep, optimize, use_4_vector, wasm_env_name, shared_library);
    b.installArtifact(lib);
    lib.step.dependOn(&headers.step);

    // Zig module
    const luauModule = b.addModule("luau", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    try buildAndLinkModule(b, target, luau_dep, luauModule, config, c_module, lib, use_4_vector);

    // Tests
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    try buildAndLinkModule(b, target, luau_dep, lib_tests.root_module, config, c_module, lib, use_4_vector);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("luau", luauModule);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zig-luau tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_tests.step);

    // Examples
    const examples = [_]struct { []const u8, []const u8 }{
        .{ "luau-bytecode", "examples/luau-bytecode.zig" },
        .{ "repl", "examples/repl.zig" },
        .{ "zig-fn", "examples/zig-fn.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example[0],
            .root_source_file = b.path(example[1]),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("luau", luauModule);

        const artifact = b.addInstallArtifact(exe, .{});
        const exe_step = b.step(b.fmt("install-example-{s}", .{example[0]}), b.fmt("Install {s} example", .{example[0]}));
        exe_step.dependOn(&artifact.step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args|
            run_cmd.addArgs(args);

        const run_step = b.step(b.fmt("run-example-{s}", .{example[0]}), b.fmt("Run {s} example", .{example[0]}));
        run_step.dependOn(&run_cmd.step);
    }

    const docs = b.addStaticLibrary(.{
        .name = "luau",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs.root_module.addOptions("config", config);
    docs.root_module.addImport("luau", luauModule);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build and install the documentation");
    docs_step.dependOn(&install_docs.step);
}

pub fn addModuleExportSymbols(b: *Build, module: *Build.Module) void {
    if (module.resolved_target.?.result.ofmt == .wasm) {
        var old_export_symbols = std.ArrayList([]const u8).init(b.allocator);
        old_export_symbols.appendSlice(module.export_symbol_names) catch @panic("OOM");
        old_export_symbols.appendSlice(&.{
            "zig_luau_try_impl",
            "zig_luau_catch_impl",
        }) catch @panic("OOM");
        module.export_symbol_names = old_export_symbols.toOwnedSlice() catch @panic("OOM");
    }
}

fn buildAndLinkModule(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    module: *Build.Module,
    config: *Step.Options,
    c_module: *Build.Module,
    lib: *Step.Compile,
    use_4_vector: bool,
) !void {
    module.addImport("c", c_module);

    module.addOptions("config", config);

    const vector_size: usize = if (use_4_vector) 4 else 3;
    module.addCMacro("LUA_VECTOR_SIZE", b.fmt("{}", .{vector_size}));

    module.addIncludePath(dependency.path("Compiler/include"));
    module.addIncludePath(dependency.path("VM/include"));
    if (target.result.ofmt != .wasm)
        module.addIncludePath(dependency.path("CodeGen/include"));

    module.linkLibrary(lib);
}

/// Luau has diverged enough from Lua (C++, project structure, ...) that it is easier to separate the build logic
fn buildLuau(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    use_4_vector: bool,
    wasm_env_name: []const u8,
    shared_library: bool,
) !*Step.Compile {
    const lib = if (shared_library) b.addSharedLibrary(.{
        .name = "luau",
        .target = target,
        .optimize = optimize,
        .version = LUAU_VERSION,
    }) else b.addStaticLibrary(.{
        .name = "luau",
        .target = target,
        .optimize = optimize,
        .version = LUAU_VERSION,
    });

    lib.root_module.pic = true;
    lib.addIncludePath(dependency.path("src/Lib"));
    lib.addIncludePath(dependency.path("Ast/include"));
    lib.addIncludePath(dependency.path("Common/include"));
    lib.addIncludePath(dependency.path("Compiler/include"));
    // CodeGen is not supported on WASM
    if (target.result.ofmt != .wasm) {
        lib.addIncludePath(dependency.path("CodeGen/include"));
    }
    lib.addIncludePath(dependency.path("VM/include"));
    lib.addIncludePath(dependency.path("VM/src"));
    lib.addIncludePath(dependency.path(""));

    const api = api: {
        if (!shared_library) break :api "extern \"C\"";
        switch (target.result.os.tag) {
            .windows => break :api "extern \"C\" __declspec(dllexport)",
            else => break :api "extern \"C\"",
        }
    };

    const FLAGS = [_][]const u8{
        // setjmp.h compile error in Wasm
        "-DLUA_USE_LONGJMP=" ++ if (target.result.ofmt != .wasm) "1" else "0",
        b.fmt("-DLUA_API={s}", .{api}),
        b.fmt("-DLUACODE_API={s}", .{api}),
        b.fmt("-DLUACODEGEN_API={s}", .{api}),
        if (use_4_vector) "-DLUA_VECTOR_SIZE=4" else "",
        if (target.result.ofmt == .wasm) "-fexceptions" else "",
        if (target.result.ofmt == .wasm) b.fmt("-DLUAU_WASM_ENV_NAME=\"{s}\"", .{wasm_env_name}) else "",
    };

    lib.linkLibCpp();
    lib.addCSourceFile(.{ .file = b.path("src/luau.cpp"), .flags = &FLAGS });

    // It may not be as likely that other software links against Luau, but might as well expose these anyway
    lib.installHeader(dependency.path("VM/include/lua.h"), "lua.h");
    lib.installHeader(dependency.path("VM/include/lualib.h"), "lualib.h");
    lib.installHeader(dependency.path("VM/include/luaconf.h"), "luaconf.h");
    if (target.result.ofmt != .wasm)
        lib.installHeader(dependency.path("CodeGen/include/luacodegen.h"), "luacodegen.h");

    return lib;
}
