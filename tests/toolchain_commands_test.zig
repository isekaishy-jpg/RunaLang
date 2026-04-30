const std = @import("std");
const compiler = @import("compiler");
const toolchain = @import("toolchain");
const cli_context = toolchain.cli.Context;
const package = toolchain.package;

test "runa check succeeds for simple package without eager store setup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\fn main() -> I32:
        \\    return 0
        \\
    );

    try withCwdExpect(root, &.{ "runa", "check" }, .parsed_success, null);
}

test "runa check rejects explicit unsupported and unknown targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
        \\[build]
        \\target = "linux"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.rna", .data =
        \\fn main() -> I32:
        \\    return 0
        \\
    });

    try withCwdExpect(root, &.{ "runa", "check" }, .command_failure, "error(s)");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
        \\[build]
        \\target = "stage0-imaginary"
        ,
    });

    try withCwdExpect(root, &.{ "runa", "check" }, .command_failure, "error(s)");
}

test "runa check fails on semantic diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\fn main() -> I32:
        \\    return false
        \\
    );

    try withCwdExpect(root, &.{ "runa", "check" }, .command_failure, "error(s)");
}

test "runa check enforces authored source line limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });

    var source = std.array_list.Managed(u8).init(std.testing.allocator);
    defer source.deinit();
    try source.appendNTimes('\n', toolchain.check.authored_line_limit + 1);
    try source.appendSlice(
        \\fn main() -> I32:
        \\    return 0
        \\
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.rna", .data = source.items });

    try withCwdExpect(root, &.{ "runa", "check" }, .command_failure, "error(s)");
}

test "runa check enforces lib child module rule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data = "pub const VALUE: I32 = 1\n",
    });

    try withCwdExpect(root, &.{ "runa", "check" }, .command_failure, "error(s)");
}

test "runa check reports structural and semantic diagnostics together" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data =
        \\pub fn value() -> I32:
        \\    return false
        \\
        ,
    });

    const absolute_root = try absolutePath(root);
    defer std.testing.allocator.free(absolute_root);
    const absolute_registry_root = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_registry_root);

    var ctx = try commandContextForPackage(absolute_root, absolute_registry_root, null);
    defer ctx.deinit();
    var result = try toolchain.check.runManifestRooted(std.testing.allocator, std.testing.io, &ctx);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(diagnosticsContainCode(&result.active.pipeline.diagnostics, "check.lib.child_module_missing"));
    try std.testing.expect(diagnosticsContainCode(&result.active.pipeline.diagnostics, "type.return.mismatch"));
}

test "runa check from workspace member uses workspace-wide scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const packages_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "packages" });
    defer std.testing.allocator.free(packages_dir);
    const app_dir = try std.fs.path.join(std.testing.allocator, &.{ packages_dir, "app" });
    defer std.testing.allocator.free(app_dir);
    const tool_dir = try std.fs.path.join(std.testing.allocator, &.{ packages_dir, "tool" });
    defer std.testing.allocator.free(tool_dir);

    try std.Io.Dir.cwd().createDir(std.testing.io, packages_dir, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, app_dir, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, tool_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[workspace]
        \\members = ["packages/app", "packages/tool"]
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packages/app/runa.toml",
        .data = packageManifest("app"),
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "packages/app/main.rna", .data =
        \\fn main() -> I32:
        \\    return 0
        \\
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packages/tool/runa.toml",
        .data = packageManifest("tool"),
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "packages/tool/main.rna", .data =
        \\fn main() -> I32:
        \\    return false
        \\
    });

    try withCwdExpect(app_dir, &.{ "runa", "check" }, .command_failure, "error(s)");
}

test "runa build release surfaces artifact under dist and intermediates under target" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.rna", .data =
        \\fn main() -> I32:
        \\    return 0
        \\
    });

    try withCwdExpect(root, &.{ "runa", "build", "--release", "--bin=demo_app" }, .parsed_success, null);

    const artifact_name = try std.fmt.allocPrint(std.testing.allocator, "demo_app{s}", .{compiler.target.hostExecutableExtension()});
    defer std.testing.allocator.free(artifact_name);
    const artifact_path = try std.fs.path.join(std.testing.allocator, &.{
        root,
        "dist",
        compiler.target.hostName(),
        "demo",
        "demo_app",
        artifact_name,
    });
    defer std.testing.allocator.free(artifact_path);
    const c_path = try std.fs.path.join(std.testing.allocator, &.{
        root,
        "target",
        compiler.target.hostName(),
        "release",
        "demo",
        "demo_app",
        "demo_app.c",
    });
    defer std.testing.allocator.free(c_path);

    try std.Io.Dir.cwd().access(std.testing.io, artifact_path, .{});
    try std.Io.Dir.cwd().access(std.testing.io, c_path, .{});
}

test "runa build rejects missing exact product selector" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\fn main() -> I32:
        \\    return 0
        \\
    );

    try withCwdExpect(root, &.{ "runa", "build", "--bin=missing" }, .command_failure, "error(s)");
}

test "public runa new fmt check build and execute end to end" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const package_root = try std.fs.path.join(std.testing.allocator, &.{ root, "demo" });
    defer std.testing.allocator.free(package_root);

    try withCwdExpect(root, &.{ "runa", "new", "demo" }, .parsed_success, null);
    const main_path = try std.fs.path.join(std.testing.allocator, &.{ package_root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = main_path,
        .data =
        \\fn main() -> I32:
        \\  return 7
        \\
        ,
    });

    try withCwdExpect(package_root, &.{ "runa", "fmt" }, .parsed_success, null);
    try withCwdExpect(package_root, &.{ "runa", "check" }, .parsed_success, null);
    try withCwdExpect(package_root, &.{ "runa", "build" }, .parsed_success, null);

    const artifact_path = try debugExecutablePath(package_root, "demo", "demo");
    defer std.testing.allocator.free(artifact_path);
    const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{artifact_path},
        .cwd = .inherit,
    });
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);

    switch (run_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
        else => return error.UnexpectedTestResult,
    }
}

test "runa fmt check reports mismatch without rewriting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    const unformatted =
        \\fn main() -> I32:
        \\  return 0
        \\
    ;
    try writeBinPackage(&tmp, "demo", unformatted);

    try withCwdExpect(root, &.{ "runa", "fmt", "--check" }, .command_failure, "need formatting");

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(unformatted, after);
}

test "runa fmt rewrites parse-valid semantic-invalid source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\fn main() -> I32:
        \\  return false
        \\
    );

    try withCwdExpect(root, &.{ "runa", "fmt" }, .parsed_success, null);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(
        \\fn main() -> I32:
        \\    return false
        \\
    , after);
}

test "runa fmt is idempotent and preserves comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\// file marker
        \\fn main() -> I32:
        \\  return 0 // result marker
        \\
    );

    try withCwdExpect(root, &.{ "runa", "fmt" }, .parsed_success, null);
    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    const first = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "// file marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "// result marker") != null);

    try withCwdExpect(root, &.{ "runa", "fmt" }, .parsed_success, null);
    const second = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "runa fmt does not rewrite on parse failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    const malformed =
        \\fn main() -> I32:
        \\return 0
        \\
    ;
    try writeBinPackage(&tmp, "demo", malformed);

    try withCwdExpect(root, &.{ "runa", "fmt" }, .command_failure, "blocking format error");

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(malformed, after);
}

test "runa fmt fails atomically when rewrite temp path exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    const unformatted =
        \\fn main() -> I32:
        \\  return 0
        \\
    ;
    try writeBinPackage(&tmp, "demo", unformatted);
    const extra_unformatted =
        \\pub fn helper() -> I32:
        \\  return 1
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zz.rna", .data = extra_unformatted });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zz.rna.tmp", .data = "occupied" });

    try withCwdExpect(root, &.{ "runa", "fmt" }, .command_failure, "AtomicRewriteTempExists");

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(unformatted, after);
    const extra_path = try std.fs.path.join(std.testing.allocator, &.{ root, "zz.rna" });
    defer std.testing.allocator.free(extra_path);
    const extra_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, extra_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(extra_after);
    try std.testing.expectEqualStrings(extra_unformatted, extra_after);
    const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ root, "zz.rna.tmp" });
    defer std.testing.allocator.free(tmp_path);
    const tmp_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, tmp_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(tmp_after);
    try std.testing.expectEqualStrings("occupied", tmp_after);
}

test "runa fmt skips external path dependency sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "dep" });
    defer std.testing.allocator.free(dep_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, app_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep_root, .default_dir);

    try writeExternalPathApp(app_root);
    try writeExternalPathDep(dep_root);

    const dep_lib = try std.fs.path.join(std.testing.allocator, &.{ dep_root, "lib.rna" });
    defer std.testing.allocator.free(dep_lib);
    const dep_before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, dep_lib, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(dep_before);

    try withCwdExpect(app_root, &.{ "runa", "fmt" }, .parsed_success, null);

    const app_main = try std.fs.path.join(std.testing.allocator, &.{ app_root, "main.rna" });
    defer std.testing.allocator.free(app_main);
    const app_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, app_main, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(app_after);
    try std.testing.expectEqualStrings(
        \\use dep.value as dep_value
        \\
        \\fn main() -> I32:
        \\    return dep_value :: :: call
        \\
    , app_after);

    const dep_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, dep_lib, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(dep_after);
    try std.testing.expectEqualStrings(dep_before, dep_after);
}

test "runa fmt skips undeclared vendor sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\fn main() -> I32:
        \\  return 0
        \\
    );
    try tmp.dir.createDir(std.testing.io, "vendor", .default_dir);
    try tmp.dir.createDir(std.testing.io, "vendor/unused", .default_dir);
    const vendor_source =
        \\pub fn value() -> I32:
        \\  return 99
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vendor/unused/lib.rna", .data = vendor_source });

    try withCwdExpect(root, &.{ "runa", "fmt" }, .parsed_success, null);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    const main_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(main_after);
    try std.testing.expectEqualStrings(
        \\fn main() -> I32:
        \\    return 0
        \\
    , main_after);

    const vendor_path = try std.fs.path.join(std.testing.allocator, &.{ root, "vendor", "unused", "lib.rna" });
    defer std.testing.allocator.free(vendor_path);
    const vendor_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, vendor_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(vendor_after);
    try std.testing.expectEqualStrings(vendor_source, vendor_after);
}

test "runa fmt formats unreferenced local sources without loading missing path deps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\missing = { path = "../missing", version = "2026.0.01" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.rna", .data =
        \\fn main() -> I32:
        \\  return 0
        \\
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unused.rna", .data =
        \\pub fn helper() -> I32:
        \\  return 1
        \\
    });

    try withCwdExpect(root, &.{ "runa", "fmt" }, .parsed_success, null);

    const unused_path = try std.fs.path.join(std.testing.allocator, &.{ root, "unused.rna" });
    defer std.testing.allocator.free(unused_path);
    const unused_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, unused_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(unused_after);
    try std.testing.expectEqualStrings(
        \\pub fn helper() -> I32:
        \\    return 1
        \\
    , unused_after);
}

test "runa test executes query-discovered unit tests" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\#test
        \\fn ok() -> Unit:
        \\    return
        \\
    );

    try withCwdExpect(root, &.{ "runa", "test" }, .parsed_success, null);
}

test "runa test supports binary main and child module tests" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDir(std.testing.io, "suite", .default_dir);
    try writeBinPackage(&tmp, "demo",
        \\mod suite
        \\
        \\fn main() -> I32:
        \\    return 0
        \\
        \\#test
        \\fn root_ok() -> Unit:
        \\    return
        \\
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "suite/mod.rna", .data =
        \\#test
        \\fn child_ok() -> Unit:
        \\    return
        \\
    });

    try withCwdExpect(root, &.{ "runa", "test", "--parallel" }, .parsed_success, null);
}

test "runa test accounts every test in a failing package" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\#test
        \\fn ok_unit() -> Unit:
        \\    return
        \\
        \\#test
        \\fn bad_result() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad" :: call
        \\
        \\#test
        \\fn ok_result() -> Result[Unit, Str]:
        \\    return Result.Ok :: :: call
        \\
    );

    try withCwdExpect(root, &.{ "runa", "test" }, .command_failure, "executed=3 passed=2 failed=1");
}

test "runa test accounts packages with more than eight failing tests" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\#test
        \\fn ok() -> Result[Unit, Str]:
        \\    return Result.Ok :: :: call
        \\
        \\#test
        \\fn bad_0() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad0" :: call
        \\
        \\#test
        \\fn bad_1() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad1" :: call
        \\
        \\#test
        \\fn bad_2() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad2" :: call
        \\
        \\#test
        \\fn bad_3() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad3" :: call
        \\
        \\#test
        \\fn bad_4() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad4" :: call
        \\
        \\#test
        \\fn bad_5() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad5" :: call
        \\
        \\#test
        \\fn bad_6() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad6" :: call
        \\
        \\#test
        \\fn bad_7() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad7" :: call
        \\
        \\#test
        \\fn bad_8() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad8" :: call
        \\
    );

    try withCwdExpect(root, &.{ "runa", "test" }, .command_failure, "executed=10 passed=1 failed=9");
}

test "runa test excludes external path dependency tests" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "dep" });
    defer std.testing.allocator.free(dep_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, app_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep_root, .default_dir);

    try writeExternalPathApp(app_root);
    try writeExternalPathDep(dep_root);

    try withCwdExpect(app_root, &.{ "runa", "test", "--parallel" }, .parsed_success, null);
}

test "runa test no-capture keeps exact later failure identity" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);

    try writeBinPackage(&tmp, "demo",
        \\#test
        \\fn ok_first() -> Result[Unit, Str]:
        \\    return Result.Ok :: :: call
        \\
        \\#test
        \\fn bad_later() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad" :: call
        \\
    );

    const absolute_root = try absolutePath(root);
    defer std.testing.allocator.free(absolute_root);
    const absolute_registry_root = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_registry_root);

    var ctx = try commandContextForPackage(absolute_root, absolute_registry_root, null);
    defer ctx.deinit();
    var result = try toolchain.testing.runManifestRooted(std.testing.allocator, std.testing.io, &ctx, .{ .no_capture = true });
    defer result.deinit();

    try std.testing.expect(result.failed());
    try std.testing.expectEqual(@as(usize, 2), result.summary.discovered);
    try std.testing.expectEqual(@as(usize, 2), result.summary.executed);
    try std.testing.expectEqual(@as(usize, 1), result.summary.passed);
    try std.testing.expectEqual(@as(usize, 1), result.summary.failed);
    try std.testing.expectEqual(@as(usize, 2), result.progress.items.len);
    try std.testing.expect(result.progress.items[0].passed);
    try std.testing.expectEqualStrings("ok_first", result.progress.items[0].function_name);
    try std.testing.expect(!result.progress.items[1].passed);
    try std.testing.expectEqualStrings("bad_later", result.progress.items[1].function_name);
}

test "runa test marker conflicts keep exact later failure identity" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);

    try writeBinPackage(&tmp, "demo",
        \\#link[name = "msvcrt"]
        \\#unsafe
        \\extern["c"] fn putchar(value: CInt) -> CInt
        \\
        \\#test
        \\fn ok_first() -> Result[Unit, Str]:
        \\    return Result.Ok :: :: call
        \\
        \\#test
        \\fn bad_later() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad" :: call
        \\
    );

    const absolute_root = try absolutePath(root);
    defer std.testing.allocator.free(absolute_root);
    const absolute_registry_root = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_registry_root);

    var ctx = try commandContextForPackage(absolute_root, absolute_registry_root, null);
    defer ctx.deinit();
    var result = try toolchain.testing.runManifestRooted(std.testing.allocator, std.testing.io, &ctx, .{});
    defer result.deinit();

    try std.testing.expect(result.failed());
    try std.testing.expectEqual(@as(usize, 2), result.summary.discovered);
    try std.testing.expectEqual(@as(usize, 2), result.summary.executed);
    try std.testing.expectEqual(@as(usize, 1), result.summary.passed);
    try std.testing.expectEqual(@as(usize, 1), result.summary.failed);
    try std.testing.expectEqual(@as(usize, 2), result.progress.items.len);
    try std.testing.expect(result.progress.items[0].passed);
    try std.testing.expectEqualStrings("ok_first", result.progress.items[0].function_name);
    try std.testing.expect(!result.progress.items[1].passed);
    try std.testing.expectEqualStrings("bad_later", result.progress.items[1].function_name);
}

test "public runa check and test end to end with test flags" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\#test
        \\fn ok() -> Result[Unit, Str]:
        \\    return Result.Ok :: :: call
        \\
    );

    try withCwdExpect(root, &.{ "runa", "check" }, .parsed_success, null);
    try withCwdExpect(root, &.{ "runa", "test", "--parallel", "--no-capture" }, .parsed_success, null);
}

test "public runa new package can be extended with tests and run through public test flow" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const package_root = try std.fs.path.join(std.testing.allocator, &.{ root, "tested" });
    defer std.testing.allocator.free(package_root);

    try withCwdExpect(root, &.{ "runa", "new", "--lib", "tested" }, .parsed_success, null);
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ package_root, "lib.rna" });
    defer std.testing.allocator.free(lib_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = lib_path,
        .data =
        \\mod core
        \\pub use core.VALUE
        \\
        \\#test
        \\fn ok() -> Result[Unit, Str]:
        \\    return Result.Ok :: :: call
        \\
        ,
    });

    try withCwdExpect(package_root, &.{ "runa", "fmt" }, .parsed_success, null);
    try withCwdExpect(package_root, &.{ "runa", "check" }, .parsed_success, null);
    try withCwdExpect(package_root, &.{ "runa", "test", "--parallel" }, .parsed_success, null);
}

test "runa test fails Result Err tests through harness execution" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try writeBinPackage(&tmp, "demo",
        \\#test
        \\fn bad() -> Result[Unit, Str]:
        \\    return Result.Err :: "bad" :: call
        \\
    );

    try withCwdExpect(root, &.{ "runa", "test" }, .command_failure, "failed=1");
}

test "runa new lib creates child-module scaffold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);

    try withCwdExpect(root, &.{ "runa", "new", "--lib", "corelib" }, .parsed_success, null);

    const package_root = try std.fs.path.join(std.testing.allocator, &.{ root, "corelib" });
    defer std.testing.allocator.free(package_root);
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ package_root, "lib.rna" });
    defer std.testing.allocator.free(lib_path);
    const core_path = try std.fs.path.join(std.testing.allocator, &.{ package_root, "core", "mod.rna" });
    defer std.testing.allocator.free(core_path);

    try std.Io.Dir.cwd().access(std.testing.io, lib_path, .{});
    try std.Io.Dir.cwd().access(std.testing.io, core_path, .{});
    try withCwdExpect(package_root, &.{ "runa", "check" }, .parsed_success, null);
}

test "runa add path and remove edit only the target package manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "dep" });
    defer std.testing.allocator.free(dep_root);

    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep_root, .default_dir);
    try writeBinPackage(&tmp, "app",
        \\fn main() -> I32:
        \\    return 0
        \\
    );
    try writeLibPackageAt(dep_root, "dep", "2026.0.02");

    try withCwdExpect(root, &.{ "runa", "add", "dep", "--path=deps/dep", "--version=2026.0.02" }, .parsed_success, null);
    {
        const path = try manifestPath(root);
        defer std.testing.allocator.free(path);
        var manifest = try package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, path);
        defer manifest.deinit();
        try std.testing.expectEqual(@as(usize, 1), manifest.dependencies.items.len);
        try std.testing.expectEqualStrings("dep", manifest.dependencies.items[0].name);
        try std.testing.expectEqualStrings("deps/dep", manifest.dependencies.items[0].path.?);
    }
    try withCwdExpect(root, &.{ "runa", "remove", "dep" }, .parsed_success, null);
    {
        const path = try manifestPath(root);
        defer std.testing.allocator.free(path);
        var manifest = try package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, path);
        defer manifest.deinit();
        try std.testing.expectEqual(@as(usize, 0), manifest.dependencies.items.len);
    }
}

test "package editing commands reject workspace-only roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[workspace]
        \\members = []
        ,
    });

    const config_path = try writeRegistryConfigFile(root, registry_root);
    defer std.testing.allocator.free(config_path);
    const absolute_config = try absolutePath(config_path);
    defer std.testing.allocator.free(absolute_config);
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("RUNA_CONFIG_PATH", absolute_config);

    try withCwdExpect(root, &.{ "runa", "add", "dep", "--path=vendor/dep" }, .command_failure, "MissingTargetPackage");
    try withCwdExpect(root, &.{ "runa", "remove", "dep" }, .command_failure, "MissingTargetPackage");
    try withCwdExpectEnv(root, &.{ "runa", "vendor", "dep", "--version=2026.0.01" }, .command_failure, "MissingTargetPackage", &env_map);
    try withCwdExpectEnv(root, &.{ "runa", "publish", "local" }, .command_failure, "MissingTargetPackage", &env_map);
}

test "package commands publish import managed add and vendor local registry sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "store" });
    defer std.testing.allocator.free(store_root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "dep" });
    defer std.testing.allocator.free(dep_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);

    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, store_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, app_root, .default_dir);
    try writeLibPackageAt(dep_root, "dep", "2026.0.02");
    try writeBinPackageAt(app_root, "app", "2026.0.01");
    const app_main = try std.fs.path.join(std.testing.allocator, &.{ app_root, "main.rna" });
    defer std.testing.allocator.free(app_main);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = app_main,
        .data =
        \\use dep.value as dep_value
        \\
        \\fn main() -> I32:
        \\    return dep_value :: :: call
        \\
        ,
    });

    var publish_ctx = try commandContextForPackage(dep_root, registry_root, null);
    defer publish_ctx.deinit();
    var published = try toolchain.pkgcmd.runPublish(std.testing.allocator, std.testing.io, &publish_ctx, .{
        .registry = "local",
    });
    defer published.deinit(std.testing.allocator);
    try std.Io.Dir.cwd().access(std.testing.io, published.source_root, .{});

    var import_ctx = try standaloneContext(root, registry_root, store_root);
    defer import_ctx.deinit();
    var imported = try toolchain.pkgcmd.runImport(std.testing.allocator, std.testing.io, &import_ctx, .{
        .name = "dep",
        .version = "2026.0.02",
    });
    defer imported.deinit(std.testing.allocator);
    try std.Io.Dir.cwd().access(std.testing.io, imported.store_entry_root, .{});

    var app_ctx = try commandContextForPackage(app_root, registry_root, store_root);
    defer app_ctx.deinit();
    var added = try toolchain.pkgcmd.runAdd(std.testing.allocator, std.testing.io, &app_ctx, .{
        .name = "dep",
        .version = "2026.0.02",
    });
    defer added.deinit(std.testing.allocator);

    {
        var app_manifest = try package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, app_ctx.target_package.?.manifest_path);
        defer app_manifest.deinit();
        try std.testing.expectEqual(@as(usize, 1), app_manifest.dependencies.items.len);
        try std.testing.expectEqualStrings("local", app_manifest.dependencies.items[0].registry.?);
    }
    var check_result = try toolchain.check.runManifestRooted(std.testing.allocator, std.testing.io, &app_ctx);
    defer check_result.deinit();
    try std.testing.expect(!check_result.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), check_result.checkedPackageCount());

    var vendored = try toolchain.pkgcmd.runVendor(std.testing.allocator, std.testing.io, &app_ctx, .{
        .name = "dep",
        .version = "2026.0.02",
    });
    defer vendored.deinit(std.testing.allocator);
    const vendored_lib = try std.fs.path.join(std.testing.allocator, &.{ vendored.vendor_root, "lib.rna" });
    defer std.testing.allocator.free(vendored_lib);
    try std.Io.Dir.cwd().access(std.testing.io, vendored_lib, .{});

    {
        var app_manifest = try package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, app_ctx.target_package.?.manifest_path);
        defer app_manifest.deinit();
        try std.testing.expectEqual(@as(usize, 1), app_manifest.dependencies.items.len);
        try std.testing.expect(app_manifest.dependencies.items[0].registry == null);
        try std.testing.expectEqualStrings("vendor/dep", app_manifest.dependencies.items[0].path.?);
    }
}

test "public runa import add check managed dependency flow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "store" });
    defer std.testing.allocator.free(store_root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "dep" });
    defer std.testing.allocator.free(dep_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);

    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, store_root, .default_dir);
    try withCwdExpect(root, &.{ "runa", "new", "--lib", "dep" }, .parsed_success, null);
    try withCwdExpect(root, &.{ "runa", "new", "app" }, .parsed_success, null);
    const dep_lib = try std.fs.path.join(std.testing.allocator, &.{ dep_root, "lib.rna" });
    defer std.testing.allocator.free(dep_lib);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_lib,
        .data =
        \\pub fn value() -> I32:
        \\  return 2
        \\
        ,
    });
    const app_main = try std.fs.path.join(std.testing.allocator, &.{ app_root, "main.rna" });
    defer std.testing.allocator.free(app_main);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = app_main,
        .data =
        \\use dep.value as dep_value
        \\
        \\fn main() -> I32:
        \\    return dep_value :: :: call
        \\
        ,
    });

    const config_path = try writeRegistryConfigFile(root, registry_root);
    defer std.testing.allocator.free(config_path);
    const absolute_config = try absolutePath(config_path);
    defer std.testing.allocator.free(absolute_config);
    const absolute_store = try absolutePath(store_root);
    defer std.testing.allocator.free(absolute_store);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("RUNA_CONFIG_PATH", absolute_config);
    try env_map.put("RUNA_STORE_ROOT", absolute_store);

    try withCwdExpectEnv(dep_root, &.{ "runa", "publish", "local" }, .parsed_success, null, &env_map);
    try withCwdExpectEnv(root, &.{ "runa", "import", "dep", "--version=2026.0.01" }, .parsed_success, null, &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "add", "dep", "--version=2026.0.01" }, .parsed_success, null, &env_map);
    const store_lib = try std.fs.path.join(std.testing.allocator, &.{ store_root, "sources", "local", "dep", "2026.0.01", "sources", "lib.rna" });
    defer std.testing.allocator.free(store_lib);
    const store_before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, store_lib, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(store_before);
    try withCwdExpectEnv(app_root, &.{ "runa", "fmt" }, .parsed_success, null, &env_map);
    const store_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, store_lib, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(store_after);
    try std.testing.expectEqualStrings(store_before, store_after);
    try withCwdExpectEnv(app_root, &.{ "runa", "check" }, .parsed_success, null, &env_map);

    if (compiler.target.stage0WindowsHostSupported()) {
        try withCwdExpectEnv(app_root, &.{ "runa", "build" }, .parsed_success, null, &env_map);
        const artifact_path = try debugExecutablePath(app_root, "app", "app");
        defer std.testing.allocator.free(artifact_path);
        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact_path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);
        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 2), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "public runa vendor supports canonical vendored dependency flow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "dep" });
    defer std.testing.allocator.free(dep_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);

    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);
    try withCwdExpect(root, &.{ "runa", "new", "--lib", "dep" }, .parsed_success, null);
    try withCwdExpect(root, &.{ "runa", "new", "app" }, .parsed_success, null);

    const dep_lib = try std.fs.path.join(std.testing.allocator, &.{ dep_root, "lib.rna" });
    defer std.testing.allocator.free(dep_lib);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_lib,
        .data =
        \\pub fn value() -> I32:
        \\  return 3
        \\
        ,
    });
    const app_main = try std.fs.path.join(std.testing.allocator, &.{ app_root, "main.rna" });
    defer std.testing.allocator.free(app_main);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = app_main,
        .data =
        \\use dep.value as dep_value
        \\
        \\fn main() -> I32:
        \\  return dep_value :: :: call
        \\
        ,
    });

    const config_path = try writeRegistryConfigFile(root, registry_root);
    defer std.testing.allocator.free(config_path);
    const absolute_config = try absolutePath(config_path);
    defer std.testing.allocator.free(absolute_config);
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("RUNA_CONFIG_PATH", absolute_config);

    try withCwdExpectEnv(dep_root, &.{ "runa", "publish", "local" }, .parsed_success, null, &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "vendor", "dep", "--version=2026.0.01" }, .parsed_success, null, &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "vendor", "dep", "--version=2026.0.01" }, .command_failure, "VendorAlreadyExists", &env_map);

    const vendored_lib = try std.fs.path.join(std.testing.allocator, &.{ app_root, "vendor", "dep", "lib.rna" });
    defer std.testing.allocator.free(vendored_lib);
    const vendored_before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, vendored_lib, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(vendored_before);

    try withCwdExpectEnv(app_root, &.{ "runa", "fmt" }, .parsed_success, null, &env_map);
    const vendored_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, vendored_lib, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(vendored_after);
    try std.testing.expect(!std.mem.eql(u8, vendored_before, vendored_after));
    try std.testing.expectEqualStrings(
        \\pub fn value() -> I32:
        \\    return 3
        \\
    , vendored_after);

    {
        const path = try manifestPath(app_root);
        defer std.testing.allocator.free(path);
        var manifest = try package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, path);
        defer manifest.deinit();
        try std.testing.expectEqual(@as(usize, 1), manifest.dependencies.items.len);
        try std.testing.expect(manifest.dependencies.items[0].registry == null);
        try std.testing.expectEqualStrings("vendor/dep", manifest.dependencies.items[0].path.?);
    }

    try withCwdExpectEnv(app_root, &.{ "runa", "check" }, .parsed_success, null, &env_map);
    if (compiler.target.stage0WindowsHostSupported()) {
        try withCwdExpectEnv(app_root, &.{ "runa", "build" }, .parsed_success, null, &env_map);
        const artifact_path = try debugExecutablePath(app_root, "app", "app");
        defer std.testing.allocator.free(artifact_path);
        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact_path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);
        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 3), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "public package commands fail loudly for registry selection and integrity errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "store" });
    defer std.testing.allocator.free(store_root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "dep" });
    defer std.testing.allocator.free(dep_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);

    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, store_root, .default_dir);
    try withCwdExpect(root, &.{ "runa", "new", "--lib", "dep" }, .parsed_success, null);
    try withCwdExpect(root, &.{ "runa", "new", "app" }, .parsed_success, null);

    const dep_lib = try std.fs.path.join(std.testing.allocator, &.{ dep_root, "lib.rna" });
    defer std.testing.allocator.free(dep_lib);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_lib,
        .data =
        \\pub fn value() -> I32:
        \\    return 4
        \\
        ,
    });

    const config_path = try writeRegistryConfigFile(root, registry_root);
    defer std.testing.allocator.free(config_path);
    const no_default_config_path = try writeRegistryConfigFileWithoutDefault(root, registry_root);
    defer std.testing.allocator.free(no_default_config_path);
    const absolute_config = try absolutePath(config_path);
    defer std.testing.allocator.free(absolute_config);
    const absolute_no_default_config = try absolutePath(no_default_config_path);
    defer std.testing.allocator.free(absolute_no_default_config);
    const absolute_store = try absolutePath(store_root);
    defer std.testing.allocator.free(absolute_store);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("RUNA_CONFIG_PATH", absolute_config);
    try env_map.put("RUNA_STORE_ROOT", absolute_store);

    var no_default_env = std.process.Environ.Map.init(std.testing.allocator);
    defer no_default_env.deinit();
    try no_default_env.put("RUNA_CONFIG_PATH", absolute_no_default_config);
    try no_default_env.put("RUNA_STORE_ROOT", absolute_store);

    try withCwdExpectEnv(dep_root, &.{ "runa", "publish", "local" }, .parsed_success, null, &env_map);
    try withCwdExpectEnv(root, &.{ "runa", "import", "dep", "--version=2026.0.01", "--registry=missing" }, .command_failure, "UnknownRegistry", &env_map);
    try withCwdExpectEnv(root, &.{ "runa", "import", "dep", "--version=2026.0.01" }, .command_failure, "MissingDefaultRegistry", &no_default_env);
    try withCwdExpectEnv(app_root, &.{ "runa", "add", "dep", "--version=2026.0.01" }, .command_failure, null, &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "add", "dep", "--path=../dep", "--version=2026.0.01", "--registry=local" }, .usage_failure, "--path cannot be combined with --registry", &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "remove", "dep" }, .command_failure, "DependencyNotFound", &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "vendor", "dep", "--version=2026.0.01", "--registry=missing" }, .command_failure, "UnknownRegistry", &env_map);
    try withCwdExpectEnv(app_root, &.{ "runa", "vendor", "dep", "--version=2026.0.01" }, .command_failure, "MissingDefaultRegistry", &no_default_env);
    try withCwdExpectEnv(app_root, &.{ "runa", "vendor", "dep", "--version=2026.0.01", "--edition=2027" }, .command_failure, "DependencyEditionMismatch", &env_map);
    try withCwdExpect(root, &.{ "runa", "publish" }, .usage_failure, "missing registry");

    const registry_lib = try std.fs.path.join(std.testing.allocator, &.{ registry_root, "sources", "dep", "2026.0.01", "sources", "lib.rna" });
    defer std.testing.allocator.free(registry_lib);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = registry_lib,
        .data =
        \\pub fn value() -> I32:
        \\    return 5
        \\
        ,
    });
    try withCwdExpectEnv(root, &.{ "runa", "import", "dep", "--version=2026.0.01" }, .command_failure, "SourceEntryChecksumMismatch", &env_map);
}

test "public runa publish artifacts performs release build and preserves artifact identity" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempRootPath(tmp.sub_path[0..]);
    defer std.testing.allocator.free(root);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, registry_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, app_root, .default_dir);
    try writeBinPackageAt(app_root, "app", "2026.0.01");

    const config_path = try writeRegistryConfigFile(root, registry_root);
    defer std.testing.allocator.free(config_path);
    const absolute_config = try absolutePath(config_path);
    defer std.testing.allocator.free(absolute_config);
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("RUNA_CONFIG_PATH", absolute_config);

    try withCwdExpectEnv(app_root, &.{ "runa", "publish", "local", "--artifacts" }, .parsed_success, null, &env_map);

    const absolute_registry = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_registry);
    const artifact_name = try std.fmt.allocPrint(std.testing.allocator, "app{s}", .{compiler.target.hostExecutableExtension()});
    defer std.testing.allocator.free(artifact_name);
    const artifact_path = try std.fs.path.join(std.testing.allocator, &.{
        absolute_registry,
        "artifacts",
        "app",
        "2026.0.01",
        "app",
        "bin",
        compiler.target.hostName(),
        "payload",
        artifact_name,
    });
    defer std.testing.allocator.free(artifact_path);
    try std.Io.Dir.cwd().access(std.testing.io, artifact_path, .{});
}

const ExpectedOutcome = enum {
    parsed_success,
    usage_failure,
    command_failure,
};

fn withCwdExpect(root: []const u8, argv: []const []const u8, expected: ExpectedOutcome, message_part: ?[]const u8) !void {
    return withCwdExpectEnv(root, argv, expected, message_part, null);
}

fn withCwdExpectEnv(
    root: []const u8,
    argv: []const []const u8,
    expected: ExpectedOutcome,
    message_part: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    const original = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original);
    try std.process.setCurrentPath(std.testing.io, root);
    defer std.process.setCurrentPath(std.testing.io, original) catch unreachable;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = if (env_map) |map|
        try toolchain.cli.runQuietForTestWithEnvMap(arena.allocator(), std.testing.io, argv, map)
    else
        try toolchain.cli.runQuietForTest(arena.allocator(), std.testing.io, argv);
    switch (expected) {
        .parsed_success => try std.testing.expect(outcome == .parsed_success),
        .usage_failure => switch (outcome) {
            .usage_failure => |line| {
                if (message_part) |needle| {
                    try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
                }
            },
            else => return error.UnexpectedTestResult,
        },
        .command_failure => switch (outcome) {
            .command_failure => |line| {
                if (message_part) |needle| {
                    try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
                }
            },
            else => return error.UnexpectedTestResult,
        },
    }
}

fn writeBinPackage(tmp: *std.testing.TmpDir, comptime name: []const u8, main_source: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data = packageManifest(name),
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.rna", .data = main_source });
}

fn packageManifest(comptime name: []const u8) []const u8 {
    return
    \\[package]
    \\
    ++ "name = \"" ++ name ++ "\"\n" ++
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
    ;
}

fn tempRootPath(sub_path: []const u8) ![]u8 {
    return std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", sub_path });
}

fn manifestPath(root: []const u8) ![]const u8 {
    return std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
}

fn debugExecutablePath(root: []const u8, comptime package_name: []const u8, comptime product_name: []const u8) ![]const u8 {
    const artifact_name = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ product_name, compiler.target.hostExecutableExtension() });
    defer std.testing.allocator.free(artifact_name);
    return std.fs.path.join(std.testing.allocator, &.{
        root,
        "target",
        compiler.target.hostName(),
        "debug",
        package_name,
        product_name,
        artifact_name,
    });
}

fn writeExternalPathApp(root: []const u8) !void {
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(manifest_path);
    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data =
        \\[package]
        \\name = "app"
        \\version = "2026.0.01"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\dep = { path = "../dep", version = "2026.0.02" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = main_path,
        .data =
        \\use dep.value as dep_value
        \\
        \\fn main() -> I32:
        \\  return dep_value :: :: call
        \\
        ,
    });
}

fn writeExternalPathDep(root: []const u8) !void {
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(manifest_path);
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ root, "lib.rna" });
    defer std.testing.allocator.free(lib_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data =
        \\[package]
        \\name = "dep"
        \\version = "2026.0.02"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = lib_path,
        .data =
        \\pub fn value() -> I32:
        \\  return 2
        \\
        \\#test
        \\fn dep_bad() -> Result[Unit, Str]:
        \\    return Result.Err :: "dep" :: call
        \\
        ,
    });
}

fn writeBinPackageAt(root: []const u8, comptime name: []const u8, comptime version: []const u8) !void {
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(manifest_path);
    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data =
        \\[package]
        \\
        ++ "name = \"" ++ name ++ "\"\n" ++
            "version = \"" ++ version ++ "\"\n" ++
            \\edition = "2026"
            \\lang_version = "0.00"
            \\
            \\[[products]]
            \\kind = "bin"
            \\root = "main.rna"
            \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = main_path,
        .data =
        \\fn main() -> I32:
        \\    return 0
        \\
        ,
    });
}

fn writeLibPackageAt(root: []const u8, comptime name: []const u8, comptime version: []const u8) !void {
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(manifest_path);
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ root, "lib.rna" });
    defer std.testing.allocator.free(lib_path);
    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "core" });
    defer std.testing.allocator.free(core_dir);
    const core_path = try std.fs.path.join(std.testing.allocator, &.{ core_dir, "mod.rna" });
    defer std.testing.allocator.free(core_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data =
        \\[package]
        \\
        ++ "name = \"" ++ name ++ "\"\n" ++
            "version = \"" ++ version ++ "\"\n" ++
            \\edition = "2026"
            \\lang_version = "0.00"
            \\
            \\[[products]]
            \\kind = "lib"
            \\root = "lib.rna"
            \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = lib_path,
        .data =
        \\mod core
        \\use core.VALUE
        \\
        \\pub fn value() -> I32:
        \\    return VALUE
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = core_path,
        .data =
        \\pub(package) const VALUE: I32 = 2
        \\
        ,
    });
}

fn registryConfig(registry_root: []const u8) !package.RegistryConfig {
    const absolute_root = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_root);
    const doc = try std.fmt.allocPrint(std.testing.allocator,
        \\default_registry = "local"
        \\
        \\[registries.local]
        \\root = "{s}"
        \\
    , .{absolute_root});
    defer std.testing.allocator.free(doc);
    return package.RegistryConfig.parse(std.testing.allocator, "test-config.toml", doc);
}

fn writeRegistryConfigFile(root: []const u8, registry_root: []const u8) ![]const u8 {
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config.toml" });
    errdefer std.testing.allocator.free(config_path);
    const absolute_registry = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_registry);
    const doc = try std.fmt.allocPrint(std.testing.allocator,
        \\default_registry = "local"
        \\
        \\[registries.local]
        \\root = "{s}"
        \\
    , .{absolute_registry});
    defer std.testing.allocator.free(doc);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = doc });
    return config_path;
}

fn writeRegistryConfigFileWithoutDefault(root: []const u8, registry_root: []const u8) ![]const u8 {
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config-no-default.toml" });
    errdefer std.testing.allocator.free(config_path);
    const absolute_registry = try absolutePath(registry_root);
    defer std.testing.allocator.free(absolute_registry);
    const doc = try std.fmt.allocPrint(std.testing.allocator,
        \\[registries.local]
        \\root = "{s}"
        \\
    , .{absolute_registry});
    defer std.testing.allocator.free(doc);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = doc });
    return config_path;
}

fn absolutePath(path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return std.testing.allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    return std.fs.path.join(std.testing.allocator, &.{ cwd, path });
}

fn diagnosticsContainCode(diagnostics: *const compiler.diag.Bag, code: []const u8) bool {
    for (diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, code)) return true;
    }
    return false;
}

fn commandContextForPackage(root: []const u8, registry_root: []const u8, store_root: ?[]const u8) !cli_context.ManifestRootedContext {
    const load_manifest_path = try manifestPath(root);
    defer std.testing.allocator.free(load_manifest_path);
    var manifest = try package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, load_manifest_path);
    defer manifest.deinit();
    const manifest_path_value = try manifestPath(root);
    const lockfile_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.lock" });
    errdefer std.testing.allocator.free(lockfile_path);
    const store = if (store_root) |value| try package.GlobalStore.initAtRoot(std.testing.allocator, value) else null;
    return .{
        .allocator = std.testing.allocator,
        .cwd = try std.testing.allocator.dupeZ(u8, root),
        .invoked_manifest_candidate = try std.testing.allocator.dupe(u8, manifest_path_value),
        .command_root = try std.testing.allocator.dupe(u8, root),
        .command_root_kind = .standalone_package,
        .target_package = .{
            .name = try std.testing.allocator.dupe(u8, manifest.name.?),
            .root_dir = try std.testing.allocator.dupe(u8, root),
            .manifest_path = manifest_path_value,
        },
        .lockfile_path = lockfile_path,
        .global_store = store,
        .registry_config = try registryConfig(registry_root),
    };
}

fn standaloneContext(cwd: []const u8, registry_root: []const u8, store_root: []const u8) !cli_context.StandaloneContext {
    return .{
        .allocator = std.testing.allocator,
        .cwd = try std.testing.allocator.dupeZ(u8, cwd),
        .global_store = try package.GlobalStore.initAtRoot(std.testing.allocator, store_root),
        .registry_config = try registryConfig(registry_root),
    };
}
