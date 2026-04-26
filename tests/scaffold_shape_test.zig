const std = @import("std");
const bootstrap = @import("bootstrap");
const compiler = @import("compiler");
const toolchain = @import("toolchain");
const libraries = @import("libraries");
const runa = @import("runa_cli");

fn satisfiesTraitForTest(
    active: *compiler.session.Session,
    module_id: compiler.session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    where_predicates: []const compiler.typed.WherePredicate,
) !compiler.query.TraitGoalResult {
    const key = try compiler.query.testing.traitGoalKeyByName(active, module_id, self_type_name, trait_name, where_predicates);
    return compiler.query.satisfiesTraitKey(active, key, where_predicates);
}

fn associatedTypeEqualsForTest(
    active: *compiler.session.Session,
    module_id: compiler.session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    associated_name: []const u8,
    value_type_name: []const u8,
    where_predicates: []const compiler.typed.WherePredicate,
) !bool {
    const key = try compiler.query.testing.traitGoalKeyByName(active, module_id, self_type_name, trait_name, where_predicates);
    return compiler.query.associatedTypeEqualsKey(active, key, associated_name, value_type_name, where_predicates);
}

test "scaffold roots exist" {
    const required = [_][]const u8{
        "cmd",
        "bootstrap",
        "compiler",
        "toolchain",
        "libraries",
        "docs",
        "spec",
        "tests",
        "examples",
        "bench",
    };

    for (required) |path| {
        try expectPathExists(path);
    }
}

test "root llm coverage exists" {
    const required = [_][]const u8{
        "compiler/llm.md",
        "toolchain/llm.md",
        "libraries/llm.md",
        "docs/llm.md",
        "tests/llm.md",
        "bench/llm.md",
    };

    for (required) |path| {
        try expectPathExists(path);
    }
}

test "compiler domains stay dense" {
    const required = [_][]const u8{
        "compiler/driver/root.zig",
        "compiler/session/root.zig",
        "compiler/query/root.zig",
        "compiler/source/root.zig",
        "compiler/diag/root.zig",
        "compiler/syntax/root.zig",
        "compiler/parse/root.zig",
        "compiler/ast/root.zig",
        "compiler/lowering/root.zig",
        "compiler/hir/root.zig",
        "compiler/typed/root.zig",
        "compiler/types/root.zig",
        "compiler/resolve/root.zig",
        "compiler/intern/root.zig",
        "compiler/metadata/root.zig",
        "compiler/ownership/root.zig",
        "compiler/borrow/root.zig",
        "compiler/lifetimes/root.zig",
        "compiler/regions/root.zig",
        "compiler/reflect/root.zig",
        "compiler/query/const_ir.zig",
        "compiler/query/const_eval.zig",
        "compiler/mir/root.zig",
        "compiler/ir/root.zig",
        "compiler/codegen/root.zig",
        "compiler/link/root.zig",
        "compiler/target/root.zig",
        "compiler/abi/root.zig",
        "compiler/runtime/root.zig",
    };

    for (required) |path| {
        try expectPathExists(path);
    }
}

test "runtime remains tiny and target-isolated" {
    try std.testing.expect(compiler.runtime.private_to_compiler);
    try std.testing.expectEqual(@as(usize, 3), compiler.runtime.owns_only.len);
    try std.testing.expect(compiler.runtime.forbidden.len >= 9);
    try std.testing.expectEqualStrings(compiler.target.hostName(), compiler.runtime.hostRuntimeLeafName());

    const required = [_][]const u8{
        "compiler/runtime/entry/root.zig",
        "compiler/runtime/abort/root.zig",
        "compiler/runtime/target/windows/root.zig",
        "compiler/runtime/target/linux/root.zig",
    };

    for (required) |path| {
        try expectPathExists(path);
    }
}

test "ownership and reflection reservations are explicit" {
    try std.testing.expectEqual(@as(usize, 4), compiler.syntax.ownership_keywords.len);
    try std.testing.expectEqual(@as(usize, 4), compiler.syntax.reference_qualifiers.len);
    try std.testing.expect(compiler.ownership.explicit_by_default);
    try std.testing.expect(std.mem.eql(u8, compiler.ownership.consuming_owner, "take"));
    try std.testing.expect(std.mem.eql(u8, compiler.ownership.stable_owner, "hold"));
    try std.testing.expect(std.mem.eql(u8, compiler.borrow.consumable_unique_handle, "&take"));
    try std.testing.expect(compiler.lifetimes.explicit_everywhere);
    try std.testing.expect(compiler.regions.explicit_everywhere);
    try std.testing.expect(compiler.reflect.compile_time_first);
    try std.testing.expect(compiler.reflect.runtime_metadata_opt_in);
    try std.testing.expect(std.mem.eql(u8, compiler.reflect.runtime_visibility, "exported_only"));
}

test "toolchain and std reflection surfaces exist" {
    try std.testing.expectEqual(@as(usize, 7), toolchain.workflow_subcommands.len);
    try std.testing.expect(libraries.std.reflect.public_api);
    try std.testing.expect(libraries.std.reflect.runtime_metadata_opt_in);
    try std.testing.expect(libraries.std.reflect.exported_only_runtime_metadata);
}

test "std option and result helpers behave" {
    const MaybeInt = libraries.std.option.Option(i32);
    const IntResult = libraries.std.result.Result(i32, []const u8);

    const some_value: MaybeInt = .{ .some = 4 };
    const none_value: MaybeInt = .none;
    try std.testing.expect(some_value.isSome());
    try std.testing.expect(!some_value.isNone());
    try std.testing.expect(none_value.isNone());
    try std.testing.expectEqual(@as(i32, 9), none_value.unwrapOr(9));

    const ok_value: IntResult = .{ .ok = 7 };
    const err_value: IntResult = .{ .err = "boom" };
    try std.testing.expect(ok_value.isOk());
    try std.testing.expect(!ok_value.isErr());
    try std.testing.expect(err_value.isErr());
}

test "std list and map surfaces behave" {
    var list = libraries.std.collections_api.List(i32).init(std.testing.allocator);
    defer list.deinit();

    try list.push(1);
    try list.push(2);
    try list.insert(1, 3);
    try std.testing.expectEqual(@as(usize, 3), list.count());
    try std.testing.expectEqual(@as(i32, 3), list.remove(1));
    const popped = list.pop();
    try std.testing.expect(popped.isSome());
    try std.testing.expectEqual(@as(i32, 2), popped.some);
    list.clear();
    try std.testing.expect(list.isEmpty());

    var map = libraries.std.collections_api.Map(i32, i32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(map.isEmpty());
    const first = try map.insert(1, 10);
    try std.testing.expect(first.isNone());
    const replaced = try map.insert(1, 11);
    try std.testing.expect(replaced.isSome());
    try std.testing.expectEqual(@as(i32, 10), replaced.some);
    try std.testing.expect(map.containsKey(1));
    const removed = map.remove(1);
    try std.testing.expect(removed.isSome());
    try std.testing.expectEqual(@as(i32, 11), removed.some);
}

test "std async and boundary surfaces exist" {
    const adapters = struct {
        fn addOne(value: i32) i32 {
            return value + 1;
        }
    };

    const TaskInt = libraries.std.async_runtime.Task(i32);
    var task = TaskInt.complete(5);
    try std.testing.expect(task.completed);
    try std.testing.expect(!task.canceled);
    task.cancel();
    try std.testing.expect(task.canceled);
    try std.testing.expectEqual(@as(i32, 5), TaskInt.complete(5).await());

    const schedule = libraries.std.async_runtime.TaskSchedule{
        .priority = .High,
        .tie_break = .{ .Explicit = 3 },
    };
    try std.testing.expect(schedule.priority == .High);
    try std.testing.expectEqual(@as(usize, 3), schedule.tie_break.Explicit);
    try std.testing.expect(libraries.std.async_runtime.entry_adapter_is_explicit);
    try std.testing.expect(libraries.std.async_runtime.detached_creation_is_explicit);
    try std.testing.expect(libraries.std.async_runtime.attached_tasks_are_default);
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.block_on(adapters.addOne, @as(i32, 7)));
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.block_on_edit(adapters.addOne, @as(i32, 7)));
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.block_on_take(adapters.addOne, @as(i32, 7)));
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn(adapters.addOne, @as(i32, 7)).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_edit(adapters.addOne, @as(i32, 7)).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_take(adapters.addOne, @as(i32, 7)).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_local(adapters.addOne, @as(i32, 7)).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_local_edit(adapters.addOne, @as(i32, 7)).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_local_take(adapters.addOne, @as(i32, 7)).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_with(adapters.addOne, @as(i32, 7), schedule).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_with_edit(adapters.addOne, @as(i32, 7), schedule).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_with_take(adapters.addOne, @as(i32, 7), schedule).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_local_with(adapters.addOne, @as(i32, 7), schedule).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_local_with_edit(adapters.addOne, @as(i32, 7), schedule).await());
    try std.testing.expectEqual(@as(i32, 8), libraries.std.async_runtime.spawn_local_with_take(adapters.addOne, @as(i32, 7), schedule).await());
    libraries.std.async_runtime.spawn_detached(adapters.addOne, @as(i32, 7));
    libraries.std.async_runtime.spawn_detached_edit(adapters.addOne, @as(i32, 7));
    libraries.std.async_runtime.spawn_detached_take(adapters.addOne, @as(i32, 7));
    libraries.std.async_runtime.spawn_local_detached(adapters.addOne, @as(i32, 7));
    libraries.std.async_runtime.spawn_local_detached_edit(adapters.addOne, @as(i32, 7));
    libraries.std.async_runtime.spawn_local_detached_take(adapters.addOne, @as(i32, 7));
    libraries.std.async_runtime.spawn_detached_with(adapters.addOne, @as(i32, 7), schedule);
    libraries.std.async_runtime.spawn_detached_with_edit(adapters.addOne, @as(i32, 7), schedule);
    libraries.std.async_runtime.spawn_detached_with_take(adapters.addOne, @as(i32, 7), schedule);
    libraries.std.async_runtime.spawn_local_detached_with(adapters.addOne, @as(i32, 7), schedule);
    libraries.std.async_runtime.spawn_local_detached_with_edit(adapters.addOne, @as(i32, 7), schedule);
    libraries.std.async_runtime.spawn_local_detached_with_take(adapters.addOne, @as(i32, 7), schedule);
    try std.testing.expectEqualStrings("#boundary[api]", libraries.std.boundary_runtime.api_attribute);
}

test "bootstrap and primary cli stay wired" {
    try std.testing.expect(std.mem.eql(u8, bootstrap.stage, "stage0"));
    try std.testing.expect(runa.parseSubcommand("check") != null);
    try std.testing.expect(runa.parseSubcommand("unknown") == null);
    try std.testing.expect(compiler.target.windows.supported_stage0);
    try std.testing.expect(!compiler.target.linux.supported_stage0);
    try std.testing.expectEqual(compiler.target.host().supported_stage0, compiler.target.hostStage0Supported());
    if (compiler.target.stage0WindowsHostSupported()) {
        try std.testing.expectEqualStrings(".exe", compiler.target.hostExecutableExtension());
        try std.testing.expectEqualStrings(".dll", compiler.target.hostDynamicLibraryExtension());
    }
}

fn expectPathExists(path: []const u8) !void {
    try std.Io.Dir.cwd().access(std.testing.io, path, .{});
}

test "manifest parsing loads package identity and products" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { version = "1.2.3", registry = "primary" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });

    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(manifest_path);

    var manifest = try toolchain.package.Manifest.loadAtPath(std.testing.allocator, std.testing.io, manifest_path);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("demo", manifest.name.?);
    try std.testing.expectEqualStrings("0.1.0", manifest.version.?);
    try std.testing.expectEqual(@as(usize, 1), manifest.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.products.items.len);
    try std.testing.expectEqual(toolchain.package.ProductKind.bin, manifest.products.items[0].kind);
}

test "lockfile parsing loads source and artifact provenance" {
    const contents =
        \\[[sources]]
        \\registry = "primary"
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\checksum = "abc123"
        \\
        \\[[artifacts]]
        \\registry = "primary"
        \\name = "demo"
        \\version = "0.1.0"
        \\product = "demo_native"
        \\kind = "cdylib"
        \\target = "x86_64-pc-windows-msvc"
        \\checksum = "def456"
    ;

    var lockfile = try toolchain.package.Lockfile.parse(std.testing.allocator, contents);
    defer lockfile.deinit();

    try std.testing.expectEqual(@as(usize, 1), lockfile.sources.items.len);
    try std.testing.expectEqual(@as(usize, 1), lockfile.artifacts.items.len);
    try std.testing.expectEqualStrings("primary", lockfile.sources.items[0].registry);
    try std.testing.expectEqual(toolchain.package.ProductKind.cdylib, lockfile.artifacts.items[0].kind);
}

test "workspace loads optional runa.lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.lock",
        .data =
        \\[[sources]]
        \\registry = "primary"
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\checksum = "abc123"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    try std.testing.expect(loaded.lockfile != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.lockfile.?.sources.items.len);
}

test "workspace validates path dependency manifests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(parent);

    const root = try std.fs.path.join(std.testing.allocator, &.{ parent, "demo" });
    defer std.testing.allocator.free(root);
    const dep = try std.fs.path.join(std.testing.allocator, &.{ parent, "localdep" });
    defer std.testing.allocator.free(dep);

    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep, .default_dir);

    const root_manifest = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(root_manifest);
    const root_main = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(root_main);
    const dep_manifest = try std.fs.path.join(std.testing.allocator, &.{ dep, "runa.toml" });
    defer std.testing.allocator.free(dep_manifest);
    const dep_lib = try std.fs.path.join(std.testing.allocator, &.{ dep, "lib.rna" });
    defer std.testing.allocator.free(dep_lib);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_manifest,
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\localdep = { path = "../localdep", version = "0.2.0" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_main,
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_manifest,
        .data =
        \\[package]
        \\name = "localdep"
        \\version = "0.2.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_lib,
        .data =
        \\pub const VALUE: I32 = 1
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("demo", loaded.manifest.name.?);
}

test "workspace rejects path dependency version mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(parent);

    const root = try std.fs.path.join(std.testing.allocator, &.{ parent, "demo" });
    defer std.testing.allocator.free(root);
    const dep = try std.fs.path.join(std.testing.allocator, &.{ parent, "localdep" });
    defer std.testing.allocator.free(dep);

    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep, .default_dir);

    const root_manifest = try std.fs.path.join(std.testing.allocator, &.{ root, "runa.toml" });
    defer std.testing.allocator.free(root_manifest);
    const root_main = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(root_main);
    const dep_manifest = try std.fs.path.join(std.testing.allocator, &.{ dep, "runa.toml" });
    defer std.testing.allocator.free(dep_manifest);
    const dep_lib = try std.fs.path.join(std.testing.allocator, &.{ dep, "lib.rna" });
    defer std.testing.allocator.free(dep_lib);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_manifest,
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\localdep = { path = "../localdep", version = "0.2.0" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_main,
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_manifest,
        .data =
        \\[package]
        \\name = "localdep"
        \\version = "0.3.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dep_lib,
        .data =
        \\pub const VALUE: I32 = 1
        ,
    });

    try std.testing.expectError(error.DependencyVersionMismatch, toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root));
}

test "workspace can scaffold a new package" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(parent);

    const created = try toolchain.workspace.createPackageAtPath(std.testing.allocator, std.testing.io, parent, "demo_app");
    defer std.testing.allocator.free(created);

    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ created, "runa.toml" });
    defer std.testing.allocator.free(manifest_path);
    const main_path = try std.fs.path.join(std.testing.allocator, &.{ created, "main.rna" });
    defer std.testing.allocator.free(main_path);

    try std.Io.Dir.cwd().access(std.testing.io, manifest_path, .{});
    try std.Io.Dir.cwd().access(std.testing.io, main_path, .{});

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, created);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("demo_app", loaded.manifest.name.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.products.items.len);
    try std.testing.expectEqual(toolchain.package.ProductKind.bin, loaded.products.items[0].kind);
}

test "compiler session and query wrap the shared pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\pub const VALUE: I32 = 9
        \\
        \\#reflect
        \\pub fn main() -> I32:
        \\    return VALUE
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 1), active.sourceFileCount());
    try std.testing.expectEqual(@as(usize, 1), active.packageCount());
    try std.testing.expectEqual(@as(usize, 1), active.moduleCount());
    try std.testing.expectEqual(@as(usize, 1), active.bodyCount());
    try std.testing.expectEqual(@as(usize, 2), active.itemCount());
    try std.testing.expectEqual(@as(usize, 0), active.associatedTypeCount());
    try std.testing.expectEqual(@as(usize, 2), active.internedNameCount());

    const const_id = compiler.query.testing.findConstIdByName(&active, "VALUE").?;
    const const_result = try compiler.query.constById(&active, const_id);
    try std.testing.expectEqual(@as(i32, 9), const_result.value.i32);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[const_id.index].state);

    const value = try compiler.query.testing.evalConstByName(&active, "VALUE");
    try std.testing.expectEqual(@as(i32, 9), value.i32);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const signature = try compiler.query.checkedSignature(&active, main_item_id);
    try std.testing.expectEqualStrings("main", signature.item.name);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.signatures[main_item_id.index].state);

    const body = try compiler.query.checkedBody(&active, .{ .index = 0 });
    try std.testing.expectEqualStrings("main", body.item.name);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.bodies[0].state);

    const metadata = try compiler.query.collectRuntimeMetadata(std.testing.allocator, &active);
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqual(@as(usize, 2), metadata.len);

    const top_level = compiler.query.testing.findTopLevel(&active, "main");
    try std.testing.expect(top_level != null);
    try std.testing.expectEqual(compiler.resolve.SymbolCategory.value, top_level.?.category);
    try std.testing.expectEqualStrings("VALUE", compiler.query.testing.internedName(&active, 0).?);
}

test "compiler semantic wrappers finalize query-backed sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const VALUE: I32 = 9
        \\
        \\fn main() -> I32:
        \\    return VALUE
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.signatures[compiler.query.testing.findItemIdByName(&active, "main").?.index].state);
    const value_id = compiler.query.testing.findConstIdByName(&active, "VALUE").?;
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[value_id.index].state);
    const value = try compiler.query.constById(&active, value_id);
    try std.testing.expectEqual(@as(i32, 9), value.value.i32);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[value_id.index].state);
    try std.testing.expect(active.pipeline.modules.items[0].mir != null);
}

test "semantic ids stay dense and stable within one session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const VALUE: I32 = 9
        \\
        \\struct Box:
        \\    value: I32
        \\
        \\fn main() -> I32:
        \\    return VALUE
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 3), active.itemCount());
    try std.testing.expectEqual(@as(usize, 1), active.bodyCount());
    const value_item_id = compiler.query.testing.findItemIdByName(&active, "VALUE").?;
    const box_item_id = compiler.query.testing.findItemIdByName(&active, "Box").?;
    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    try std.testing.expectEqual(value_item_id.index, compiler.query.testing.findItemIdByName(&active, "VALUE").?.index);
    try std.testing.expectEqual(box_item_id.index, compiler.query.testing.findItemIdByName(&active, "Box").?.index);
    try std.testing.expectEqual(main_item_id.index, compiler.query.testing.findItemIdByName(&active, "main").?.index);
    try std.testing.expect(value_item_id.index < active.itemCount());
    try std.testing.expect(box_item_id.index < active.itemCount());
    try std.testing.expect(main_item_id.index < active.itemCount());

    const value_entry = active.semantic_index.itemEntry(value_item_id);
    const main_entry = active.semantic_index.itemEntry(main_item_id);
    try std.testing.expectEqual(@as(usize, 0), value_entry.const_id.?.index);
    try std.testing.expectEqual(@as(usize, 0), main_entry.body_id.?.index);
    try std.testing.expectEqual(main_item_id.index, active.semantic_index.bodyEntry(main_entry.body_id.?).item_id.index);
}

test "query diagnostics are not repeated for cached signature and body results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\const PRIVATE: I32 = 1
        \\
        \\fn helper() -> I32:
        \\    return 1
        \\
        \\fn missing() -> I32:
        \\    return
        \\
        \\fn main() -> I32:
        \\    const BAD: I32 = helper :: :: call
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const private_id = compiler.query.testing.findItemIdByName(&active, "PRIVATE").?;
    _ = try compiler.query.checkedSignature(&active, private_id);
    const signature_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.checkedSignature(&active, private_id);
    try std.testing.expectEqual(signature_diagnostic_count, active.pipeline.diagnostics.items.items.len);

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), result.summary.rejected_count);
    const body_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expectEqual(body_diagnostic_count, active.pipeline.diagnostics.items.items.len);

    const expression_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.expressionsByBody(&active, body_id);
    try std.testing.expectEqual(expression_diagnostic_count, active.pipeline.diagnostics.items.items.len);

    const missing_id = compiler.query.testing.findItemIdByName(&active, "missing").?;
    const missing_body_id = active.semantic_index.itemEntry(missing_id).body_id.?;
    const statement_result = try compiler.query.statementsByBody(&active, missing_body_id);
    try std.testing.expectEqual(@as(usize, 1), statement_result.summary.prepared_issue_count);
    const statement_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.statementsByBody(&active, missing_body_id);
    try std.testing.expectEqual(statement_diagnostic_count, active.pipeline.diagnostics.items.items.len);

    var saw_reflect_exported = false;
    var saw_const_expr = false;
    var saw_return_missing_value = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.reflect.exported")) saw_reflect_exported = true;
        if (std.mem.eql(u8, item.code, "type.const.expr")) saw_const_expr = true;
        if (std.mem.eql(u8, item.code, "type.return.missing_value")) saw_return_missing_value = true;
    }
    try std.testing.expect(saw_reflect_exported);
    try std.testing.expect(saw_const_expr);
    try std.testing.expect(saw_return_missing_value);
}

test "query cycle failures cache by family key without repeated diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\pub const VALUE: I32 = 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expect(try active.pushActiveQuery(.reflection, 0));
    try std.testing.expectError(error.QueryCycle, compiler.query.reflectionById(&active, .{ .index = 0 }));
    active.popActiveQuery();

    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.reflections[0].state);
    try std.testing.expect(active.caches.reflections[0].failed);
    const diagnostic_count = active.pipeline.diagnostics.items.items.len;
    try std.testing.expectError(error.CachedFailure, compiler.query.reflectionById(&active, .{ .index = 0 }));
    try std.testing.expectEqual(diagnostic_count, active.pipeline.diagnostics.items.items.len);
}

test "in-progress query entries become cached failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\pub const VALUE: I32 = 1
        \\
        \\fn main() -> Unit:
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const const_id = compiler.query.testing.findConstIdByName(&active, "VALUE").?;
    active.caches.consts[const_id.index].state = .in_progress;
    try std.testing.expectError(error.QueryCycle, compiler.query.constById(&active, const_id));
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[const_id.index].state);
    try std.testing.expect(active.caches.consts[const_id.index].failed);
    try std.testing.expectError(error.CachedFailure, compiler.query.constById(&active, const_id));

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    active.caches.bodies[body_id.index].state = .in_progress;
    try std.testing.expectError(error.QueryCycle, compiler.query.checkedBody(&active, body_id));
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.bodies[body_id.index].state);
    try std.testing.expect(active.caches.bodies[body_id.index].failed);
    try std.testing.expectError(error.CachedFailure, compiler.query.checkedBody(&active, body_id));
}

test "checked body summary records statements bindings and calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn helper() -> I32:
        \\    return 1
        \\
        \\fn main() -> I32:
        \\    let value: I32 = helper :: :: call
        \\    select:
        \\        when true => return value
        \\        else => return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const body = try compiler.query.checkedBody(&active, body_id);

    try std.testing.expectEqual(@as(usize, 4), body.summary.statement_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.let_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.select_count);
    try std.testing.expectEqual(@as(usize, 2), body.summary.return_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.call_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.binding_count);
    try std.testing.expectEqual(@as(usize, 3), body.summary.block_count);
    try std.testing.expectEqual(@as(usize, 2), body.block_sites[body.root_block_id].statement_indices.len);
    try std.testing.expectEqual(@as(usize, 0), body.parameters.len);
}

test "checked body exposes parameter and control-flow facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn later() -> I32:
        \\    return 1
        \\
        \\fn main(edit total: I32, read limit: I32) -> I32:
        \\    defer later :: :: call
        \\    select:
        \\        when true => return limit
        \\        else => return total
        \\    repeat while true:
        \\        break
        \\    return later :: :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const body = try compiler.query.checkedBody(&active, body_id);

    try std.testing.expectEqual(@as(usize, 2), body.parameters.len);
    try std.testing.expectEqual(@as(usize, 4), body.block_sites[body.root_block_id].statement_indices.len);
    try std.testing.expectEqual(@as(usize, 2), body.summary.parameter_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.mutable_parameter_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.edit_parameter_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.read_parameter_count);
    try std.testing.expectEqual(@as(usize, 4), body.summary.block_count);
    try std.testing.expectEqual(@as(usize, 7), body.summary.statement_count);
    try std.testing.expectEqual(@as(usize, 16), body.summary.cfg_edge_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.select_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.loop_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.defer_count);
    try std.testing.expectEqual(@as(usize, 3), body.summary.return_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.break_count);
    try std.testing.expectEqual(@as(usize, 2), body.summary.call_count);
    try std.testing.expectEqual(@as(usize, 2), body.summary.suspend_call_count);
    try std.testing.expectEqual(@as(usize, 2), body.places.len);
    try std.testing.expect(body.places[0].kind == .parameter);
    try std.testing.expectEqualStrings("total", body.places[0].name);
    try std.testing.expect(body.places[0].mutable);
    try std.testing.expect(body.places[1].kind == .parameter);
    try std.testing.expectEqualStrings("limit", body.places[1].name);
    try std.testing.expect(!body.places[1].mutable);
    try std.testing.expectEqual(@as(usize, 16), body.cfg_edges.len);
    try std.testing.expectEqual(@as(usize, 10), body.effect_sites.len);
    try std.testing.expectEqual(@as(usize, 2), body.suspension_sites.len);
    try std.testing.expectEqualStrings("later", body.suspension_sites[0].callee_name);

    var saw_loop_back = false;
    var saw_loop_condition = false;
    var saw_break_exit = false;
    var saw_return_exit = false;
    var saw_defer_exit = false;
    for (body.cfg_edges) |edge| {
        if (edge.kind == .loop_back and edge.from_statement > edge.to_statement) saw_loop_back = true;
        if (edge.kind == .loop_condition) saw_loop_condition = true;
        if (edge.kind == .break_exit) saw_break_exit = true;
        if (edge.kind == .return_exit and edge.to_statement == compiler.query.checked_body.exit_statement) saw_return_exit = true;
        if (edge.kind == .defer_exit) saw_defer_exit = true;
    }
    try std.testing.expect(saw_loop_back);
    try std.testing.expect(saw_loop_condition);
    try std.testing.expect(saw_break_exit);
    try std.testing.expect(saw_return_exit);
    try std.testing.expect(saw_defer_exit);

    var saw_suspend_boundary = false;
    for (body.effect_sites) |site| {
        if (site.kind == .suspend_boundary) saw_suspend_boundary = true;
    }
    try std.testing.expect(saw_suspend_boundary);

    const borrow_result = try compiler.query.borrowByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 2), borrow_result.summary.borrow_parameter_count);
    try std.testing.expectEqual(body.places.len, borrow_result.summary.checked_place_count);
    try std.testing.expectEqual(body.cfg_edges.len, borrow_result.summary.cfg_edge_count);
    try std.testing.expectEqual(body.effect_sites.len, borrow_result.summary.effect_site_count);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.invalid_cfg_edges);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.invalid_effect_sites);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.suspension_borrow_count);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.detached_borrow_count);
}

test "checked body exposes unsafe and spawn analyzer facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn child(take value: I32) -> I32:
        \\    return value
        \\
        \\fn spawn[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\fn launch() -> Unit:
        \\    #unsafe:
        \\        spawn :: child, 1 :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const launch_item_id = compiler.query.testing.findItemIdByName(&active, "launch").?;
    const body_id = active.semantic_index.itemEntry(launch_item_id).body_id.?;
    const body = try compiler.query.checkedBody(&active, body_id);

    try std.testing.expectEqual(@as(usize, 1), body.summary.unsafe_block_count);
    try std.testing.expectEqual(@as(usize, 1), body.summary.spawn_call_count);
    try std.testing.expectEqual(@as(usize, 1), body.spawn_sites.len);
    try std.testing.expect(body.spawn_sites[0].worker_crossing);

    var saw_unsafe = false;
    var saw_spawn_boundary = false;
    for (body.effect_sites) |site| {
        if (site.kind == .unsafe_block) saw_unsafe = true;
        if (site.kind == .spawn_boundary) saw_spawn_boundary = true;
    }
    try std.testing.expect(saw_unsafe);
    try std.testing.expect(saw_spawn_boundary);
}

test "borrow query rejects ephemeral borrow across suspension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn later() -> Unit:
        \\    return
        \\
        \\suspend fn parent(read value: I32) -> Unit:
        \\    later :: :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_suspend_borrow = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "borrow.suspend")) {
            saw_suspend_borrow = true;
            break;
        }
    }
    try std.testing.expect(saw_suspend_borrow);

    const parent_item_id = compiler.query.testing.findItemIdByName(&active, "parent").?;
    const body_id = active.semantic_index.itemEntry(parent_item_id).body_id.?;
    const borrow_result = try compiler.query.borrowByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), borrow_result.summary.suspension_borrow_count);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.detached_borrow_count);
}

test "borrow query rejects borrowed detached task input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn child(take value: I32) -> Unit:
        \\    return
        \\
        \\fn spawn_detached[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\fn parent(read value: I32) -> Unit:
        \\    spawn_detached :: child, value :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_detached_borrow = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "borrow.detached")) {
            saw_detached_borrow = true;
            break;
        }
    }
    try std.testing.expect(saw_detached_borrow);

    const parent_item_id = compiler.query.testing.findItemIdByName(&active, "parent").?;
    const body_id = active.semantic_index.itemEntry(parent_item_id).body_id.?;
    const borrow_result = try compiler.query.borrowByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.suspension_borrow_count);
    try std.testing.expectEqual(@as(usize, 1), borrow_result.summary.detached_borrow_count);
}

test "borrow query stops effects after break exits a loop body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn later() -> Unit:
        \\    return
        \\
        \\suspend fn parent(read value: I32) -> Unit:
        \\    repeat while true:
        \\        break
        \\        later :: :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "borrow.suspend"));
    }

    const parent_item_id = compiler.query.testing.findItemIdByName(&active, "parent").?;
    const body_id = active.semantic_index.itemEntry(parent_item_id).body_id.?;
    const borrow_result = try compiler.query.borrowByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 0), borrow_result.summary.suspension_borrow_count);
}

test "checked signatures expose semantic item facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\    fn clone(read self) -> Self
        \\
        \\struct Box[T]
        \\where T: Clone:
        \\    value: T
        \\
        \\const VALUE: I32 = 4
        \\
        \\suspend fn later(read value: I32) -> I32:
        \\    return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const box_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "Box").?);
    switch (box_sig.facts) {
        .struct_type => |struct_sig| {
            try std.testing.expectEqual(@as(usize, 1), struct_sig.generic_params.len);
            try std.testing.expectEqual(@as(usize, 1), struct_sig.where_predicates.len);
            try std.testing.expectEqual(@as(usize, 1), struct_sig.fields.len);
            try std.testing.expectEqualStrings("value", struct_sig.fields[0].name);
        },
        else => return error.UnexpectedStructure,
    }

    const value_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "VALUE").?);
    switch (value_sig.facts) {
        .const_item => |const_sig| {
            try std.testing.expectEqual(compiler.types.Builtin.i32, const_sig.ty);
            try std.testing.expect(const_sig.expr != null);
            try std.testing.expectEqualStrings("4", const_sig.initializer_source);
        },
        else => return error.UnexpectedStructure,
    }

    const later_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "later").?);
    switch (later_sig.facts) {
        .function => |function_sig| {
            try std.testing.expect(function_sig.is_suspend);
            try std.testing.expect(!function_sig.foreign);
            try std.testing.expectEqual(@as(usize, 1), function_sig.parameters.len);
            try std.testing.expect(function_sig.return_type.eql(compiler.types.TypeRef.fromBuiltin(.i32)));
        },
        else => return error.UnexpectedStructure,
    }

    const clone_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "Clone").?);
    switch (clone_sig.facts) {
        .trait_type => |trait_sig| {
            try std.testing.expectEqual(@as(usize, 1), trait_sig.methods.len);
            try std.testing.expectEqual(@as(usize, 0), trait_sig.associated_types.len);
            try std.testing.expectEqualStrings("clone", trait_sig.methods[0].name);
        },
        else => return error.UnexpectedStructure,
    }
}

test "query const evaluation resolves imported consts through semantic ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const util_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "util" });
    defer std.testing.allocator.free(util_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, util_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\mod util
        \\use util.VALUE
        \\
        \\const NEXT: I32 = VALUE + 1
        \\
        \\fn main() -> I32:
        \\    return NEXT
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util/mod.rna",
        .data =
        \\pub(package) const VALUE: I32 = 7
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const next_id = compiler.query.testing.findConstIdByName(&active, "NEXT").?;
    const next_value = try compiler.query.constById(&active, next_id);
    try std.testing.expectEqual(@as(i32, 8), next_value.value.i32);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[next_id.index].state);
}

test "query const evaluation caches cycles as failed results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const A: I32 = B + 1
        \\const B: I32 = A + 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const a_id = compiler.query.testing.findConstIdByName(&active, "A").?;
    try std.testing.expectError(error.QueryCycle, compiler.query.constById(&active, a_id));
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[a_id.index].state);
    try std.testing.expect(active.caches.consts[a_id.index].failed);
    const diagnostic_count = active.pipeline.diagnostics.items.items.len;
    try std.testing.expectError(error.CachedFailure, compiler.query.constById(&active, a_id));
    try std.testing.expectEqual(diagnostic_count, active.pipeline.diagnostics.items.items.len);
}

test "query const evaluation rejects divide by zero and caches failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BAD: I32 = 1 / 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const bad_id = compiler.query.testing.findConstIdByName(&active, "BAD").?;
    try std.testing.expectError(error.DivideByZero, compiler.query.constById(&active, bad_id));
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[bad_id.index].state);
    try std.testing.expect(active.caches.consts[bad_id.index].failed);
    const diagnostic_count = active.pipeline.diagnostics.items.items.len;
    try std.testing.expectError(error.CachedFailure, compiler.query.constById(&active, bad_id));
    try std.testing.expectEqual(diagnostic_count, active.pipeline.diagnostics.items.items.len);

    var saw_error = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.divide_by_zero")) saw_error = true;
    }
    try std.testing.expect(saw_error);
}

test "semantic finalize rejects invalid const remainder" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BAD: I32 = 1 % 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_remainder = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.invalid_remainder")) saw_remainder = true;
    }
    try std.testing.expect(saw_remainder);
}

test "semantic finalize rejects invalid const expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const SHIFT: I32 = 1 << 32
        \\const OVER: I32 = 2147483647 + 1
        \\const CALL: I32 = helper :: :: call
        \\
        \\fn helper() -> I32:
        \\    return 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_shift = false;
    var saw_overflow = false;
    var saw_expr = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.invalid_shift")) saw_shift = true;
        if (std.mem.eql(u8, item.code, "type.const.overflow")) saw_overflow = true;
        if (std.mem.eql(u8, item.code, "type.const.expr")) saw_expr = true;
    }
    try std.testing.expect(saw_shift);
    try std.testing.expect(saw_overflow);
    try std.testing.expect(saw_expr);
}

test "query const contexts evaluate fixed array lengths through const IR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const LEN: U32 = 4
        \\
        \\struct Packet:
        \\    values: [I32; LEN as Index]
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const len_id = compiler.query.testing.findConstIdByName(&active, "LEN").?;
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[len_id.index].state);
}

test "query const evaluation handles aggregates and static tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\const BOX: Box = Box :: 4 :: call
        \\const VALUE: I32 = BOX.value
        \\const TABLE: [I32; 2] = [3, VALUE]
        \\const FIRST: I32 = TABLE[0]
        \\const SECOND: I32 = TABLE[1]
        \\
        \\fn main() -> I32:
        \\    return VALUE
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const box = try compiler.query.testing.evalConstByName(&active, "BOX");
    switch (box) {
        .aggregate => |aggregate| {
            try std.testing.expectEqualStrings("Box", aggregate.type_name);
            try std.testing.expectEqual(@as(usize, 1), aggregate.fields.len);
            try std.testing.expectEqualStrings("value", aggregate.fields[0].name);
            try std.testing.expectEqual(@as(i32, 4), aggregate.fields[0].value.i32);
        },
        else => return error.UnexpectedTestResult,
    }

    const value = try compiler.query.testing.evalConstByName(&active, "VALUE");
    try std.testing.expectEqual(@as(i32, 4), value.i32);
    const first = try compiler.query.testing.evalConstByName(&active, "FIRST");
    try std.testing.expectEqual(@as(i32, 3), first.i32);
    const second = try compiler.query.testing.evalConstByName(&active, "SECOND");
    try std.testing.expectEqual(@as(i32, 4), second.i32);
}

test "query const evaluation handles enum value consts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Status:
        \\    Ok
        \\    Err(I32)
        \\
        \\const OK: Status = Status.Ok
        \\const ERR: Status = Status.Err :: 7 :: call
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const ok = try compiler.query.testing.evalConstByName(&active, "OK");
    switch (ok) {
        .enum_value => |enum_value| {
            try std.testing.expectEqualStrings("Status", enum_value.enum_name);
            try std.testing.expectEqualStrings("Ok", enum_value.variant_name);
            try std.testing.expectEqual(@as(i32, 0), enum_value.tag);
            try std.testing.expectEqual(@as(usize, 0), enum_value.fields.len);
        },
        else => return error.UnexpectedTestResult,
    }

    const err = try compiler.query.testing.evalConstByName(&active, "ERR");
    switch (err) {
        .enum_value => |enum_value| {
            try std.testing.expectEqualStrings("Status", enum_value.enum_name);
            try std.testing.expectEqualStrings("Err", enum_value.variant_name);
            try std.testing.expectEqual(@as(i32, 1), enum_value.tag);
            try std.testing.expectEqual(@as(usize, 1), enum_value.fields.len);
            try std.testing.expectEqualStrings("_0", enum_value.fields[0].name);
            try std.testing.expectEqual(@as(i32, 7), enum_value.fields[0].value.i32);
        },
        else => return error.UnexpectedTestResult,
    }
}

test "query const contexts reject negative fixed array lengths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const NEG: I32 = -1
        \\
        \\struct Bad:
        \\    values: [I32; NEG]
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_negative_length = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.array_length_negative")) saw_negative_length = true;
    }
    try std.testing.expect(saw_negative_length);
}

test "query const contexts evaluate repr enum discriminants through const IR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const OK_VALUE: U32 = 2
        \\
        \\#repr[c, Index]
        \\enum Status:
        \\    Ok = OK_VALUE as Index
        \\    Err = 3
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const ok_id = compiler.query.testing.findConstIdByName(&active, "OK_VALUE").?;
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[ok_id.index].state);
}

test "query const contexts reject invalid repr enum discriminants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#repr[c, I32]
        \\enum Bad:
        \\    Large = 2147483647 + 1
        \\    Divide = 1 / 0
        \\    Payload(I32) = 2
        \\    Missing
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_range = false;
    var saw_divide = false;
    var saw_payload = false;
    var saw_missing = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.enum_discriminant_range")) saw_range = true;
        if (std.mem.eql(u8, item.code, "type.const.divide_by_zero")) saw_divide = true;
        if (std.mem.eql(u8, item.code, "type.enum.repr_payload")) saw_payload = true;
        if (std.mem.eql(u8, item.code, "type.enum.discriminant_missing")) saw_missing = true;
    }
    try std.testing.expect(saw_range);
    try std.testing.expect(saw_divide);
    try std.testing.expect(saw_payload);
    try std.testing.expect(saw_missing);
}

test "query local const contexts evaluate array repetition lengths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const LEN: Index = 3
        \\
        \\fn main() -> I32:
        \\    let value: [I32; LEN] = [1; LEN]
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), result.summary.checked_array_repetition_lengths);
    try std.testing.expectEqual(@as(usize, 0), result.summary.rejected_array_repetition_lengths);

    var saw_array_stage0 = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.expr.array.stage0")) saw_array_stage0 = true;
    }
    try std.testing.expect(!saw_array_stage0);
}

test "query local const contexts reject non-const array repetition lengths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let len: I32 = 3
        \\    let value: [I32; 3] = [1; len]
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), result.summary.checked_array_repetition_lengths);
    try std.testing.expectEqual(@as(usize, 1), result.summary.rejected_array_repetition_lengths);

    var saw_repetition_length = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.array_repetition_length")) saw_repetition_length = true;
    }
    try std.testing.expect(saw_repetition_length);
}

test "query local const contexts reject invalid compile-time conversions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    const base: U32 = 1
        \\    const bad: Bool = base as Bool
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);

    try std.testing.expectEqual(@as(usize, 2), result.summary.checked_count);
    try std.testing.expectEqual(@as(usize, 1), result.summary.rejected_count);

    var saw_invalid_conversion = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.conversion")) saw_invalid_conversion = true;
    }
    try std.testing.expect(saw_invalid_conversion);
}

test "query array repetition lengths reject invalid compile-time conversions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    const flag: Bool = true
        \\    let value: [I32; 3] = [1; flag as Index]
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);

    try std.testing.expectEqual(@as(usize, 1), result.summary.checked_array_repetition_lengths);
    try std.testing.expectEqual(@as(usize, 1), result.summary.rejected_array_repetition_lengths);

    var saw_invalid_conversion = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.conversion")) saw_invalid_conversion = true;
    }
    try std.testing.expect(saw_invalid_conversion);
}

test "query local const evaluation uses const IR and earlier local bindings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BASE: I32 = 2
        \\
        \\fn main() -> I32:
        \\    const A: I32 = BASE + 3
        \\    const B: I32 = A * 2
        \\    return B
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 2), result.summary.checked_count);
    try std.testing.expectEqual(@as(usize, 0), result.summary.rejected_count);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.local_consts[body_id.index].state);
}

test "query local const evaluation rejects forward local dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    const A: I32 = B + 1
        \\    const B: I32 = 4
        \\    return A
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_unknown = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.name.unknown")) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expect(result.summary.checked_count >= 1);
}

test "query local const evaluation treats forward local cycles as unknown names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    const A: I32 = B + 1
        \\    const B: I32 = A + 1
        \\    return A
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    _ = result;

    var saw_unknown = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.name.unknown")) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);
}

test "semantic rejects explicit const-safe local const with non-const initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn helper() -> I32:
        \\    return 1
        \\
        \\fn main() -> I32:
        \\    let A: I32 = 1
        \\    const B: I32 = helper :: :: call
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_expr = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.expr")) saw_expr = true;
    }
    try std.testing.expect(saw_expr);
}

test "semantic accepts explicit local const with const-safe struct type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn main() -> I32:
        \\    const box: Box = Box :: 1 :: call
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), result.summary.checked_count);
    try std.testing.expectEqual(@as(usize, 0), result.summary.rejected_count);
}

test "semantic rejects explicit local const with opaque non-const-safe type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\opaque type Handle
        \\
        \\struct Holder:
        \\    handle: Handle
        \\
        \\fn main() -> I32:
        \\    const holder: Holder = Holder :: 0 :: call
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.localConstsByBody(&active, body_id);
    try std.testing.expect(result.summary.rejected_count >= 1);

    var saw_type = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.type")) saw_type = true;
    }
    try std.testing.expect(saw_type);
}

test "semantic rejects local const without explicit type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    const value = 1
        \\    return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_type = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.const.type")) saw_type = true;
    }
    try std.testing.expect(saw_type);
}

test "domain-state roots and contexts validate explicit parent and root anchors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\#domain_root
        \\struct SceneState['a]:
        \\    app: hold['a] edit AppState
        \\    current_level: Index
        \\
        \\#domain_context
        \\struct SceneCtx['a]:
        \\    scene: hold['a] edit SceneState['a]
        \\    frame_index: Index
        \\
        \\pub fn main() -> Unit:
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expect(!active.pipeline.diagnostics.hasErrors());

    const scene_item_id = compiler.query.testing.findItemIdByName(&active, "SceneState").?;
    const scene_domain = try compiler.query.domainStateByItem(&active, scene_item_id);
    try std.testing.expect(scene_domain.signature == .root);
    try std.testing.expect(scene_domain.signature.root.parent_anchor != null);
    try std.testing.expectEqualStrings("AppState", scene_domain.signature.root.parent_anchor.?.target_name);

    const ctx_item_id = compiler.query.testing.findItemIdByName(&active, "SceneCtx").?;
    const ctx_domain = try compiler.query.domainStateByItem(&active, ctx_item_id);
    try std.testing.expect(ctx_domain.signature == .context);
    try std.testing.expectEqualStrings("SceneState", ctx_domain.signature.context.root_anchor.target_name);
}

test "domain-state rejects multiple parent or root anchors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\#domain_root
        \\struct SceneState['a]:
        \\    app: hold['a] edit AppState
        \\    fallback: hold['a] read AppState
        \\
        \\#domain_context
        \\struct SceneCtx['a]:
        \\    app: hold['a] edit AppState
        \\    scene: hold['a] edit SceneState['a]
        \\
        \\pub fn main() -> Unit:
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    _ = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "SceneState").?);
    _ = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "SceneCtx").?);

    try std.testing.expect(active.pipeline.diagnostics.hasErrors());

    var saw_root_error = false;
    var saw_context_error = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_root.parent_anchor")) saw_root_error = true;
        if (std.mem.eql(u8, item.code, "type.domain_context.anchor_multiple")) saw_context_error = true;
    }
    try std.testing.expect(saw_root_error);
    try std.testing.expect(saw_context_error);
}

test "domain-state rejects child root without parent anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    value: I32
        \\
        \\#domain_root
        \\struct SceneState['a]:
        \\    value: I32
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_missing = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_root.parent_anchor_missing")) saw_missing = true;
    }
    try std.testing.expect(saw_missing);
}

test "domain-state rejects invalid retained anchor targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct NotRoot:
        \\    value: Index
        \\
        \\#domain_root
        \\struct LoopRoot['a]:
        \\    parent: hold['a] read LoopRoot['a]
        \\
        \\#domain_context
        \\struct BadCtx['a]:
        \\    not_root: hold['a] read NotRoot
        \\
        \\pub fn main() -> Unit:
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    _ = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "LoopRoot").?);
    _ = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "BadCtx").?);

    var saw_root_target = false;
    var saw_context_target = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_root.parent_anchor_target")) saw_root_target = true;
        if (std.mem.eql(u8, item.code, "type.domain_context.anchor_target")) saw_context_target = true;
    }
    try std.testing.expect(saw_root_target);
    try std.testing.expect(saw_context_target);
}

test "domain-state retained anchors require declared lifetimes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    value: I32
        \\
        \\#domain_root
        \\struct SceneState:
        \\    parent: hold['a] read AppState
        \\
        \\#domain_context
        \\struct EventCtx:
        \\    root: hold['a] read AppState
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_root_lifetime = false;
    var saw_context_lifetime = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_root.parent_anchor_lifetime")) saw_root_lifetime = true;
        if (std.mem.eql(u8, item.code, "type.domain_context.anchor_lifetime")) saw_context_lifetime = true;
    }
    try std.testing.expect(saw_root_lifetime);
    try std.testing.expect(saw_context_lifetime);
}

test "domain-state anchor checks resolve imported root targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const util_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "util" });
    defer std.testing.allocator.free(util_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, util_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\mod util
        \\use util.AppState
        \\
        \\#domain_root
        \\struct SceneState['a]:
        \\    app: hold['a] read AppState
        \\
        \\#domain_context
        \\struct SceneCtx['a]:
        \\    app: hold['a] edit AppState
        \\
        \\pub fn main() -> Unit:
        \\    return
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util/mod.rna",
        .data =
        \\#domain_root
        \\pub struct AppState:
        \\    counter: Index
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expect(!active.pipeline.diagnostics.hasErrors());

    const scene_domain = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "SceneState").?);
    try std.testing.expect(scene_domain.signature == .root);
    try std.testing.expectEqualStrings("AppState", scene_domain.signature.root.parent_anchor.?.target_name);

    const ctx_domain = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "SceneCtx").?);
    try std.testing.expect(ctx_domain.signature == .context);
    try std.testing.expectEqualStrings("AppState", ctx_domain.signature.context.root_anchor.target_name);
}

test "domain-state rejects imported retained anchors targeting non-roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const util_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "util" });
    defer std.testing.allocator.free(util_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, util_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\mod util
        \\use util.NotRoot
        \\
        \\#domain_context
        \\struct BadCtx['a]:
        \\    value: hold['a] read NotRoot
        \\
        \\pub fn main() -> Unit:
        \\    return
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util/mod.rna",
        .data =
        \\pub struct NotRoot:
        \\    value: Index
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    _ = try compiler.query.domainStateByItem(&active, compiler.query.testing.findItemIdByName(&active, "BadCtx").?);

    var saw_context_target = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_context.anchor_target")) saw_context_target = true;
    }
    try std.testing.expect(saw_context_target);
}

test "domain-state rejects boundary attributes on roots and contexts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#boundary[value]
        \\#domain_root
        \\pub struct AppState:
        \\    counter: Index
        \\
        \\#boundary[value]
        \\#domain_context
        \\pub struct AppCtx['a]:
        \\    app: hold['a] edit AppState
        \\
        \\pub fn main() -> Unit:
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var boundary_attr_errors: usize = 0;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.boundary_attr")) boundary_attr_errors += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), boundary_attr_errors);
}

test "domain-state rejects boundary api signatures that expose roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\#boundary[api]
        \\pub fn export(take app: AppState) -> AppState:
        \\    return app
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_param_error = false;
    var saw_return_error = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.boundary_param")) saw_param_error = true;
        if (std.mem.eql(u8, item.code, "type.domain_state.boundary_return")) saw_return_error = true;
    }

    try std.testing.expect(saw_param_error);
    try std.testing.expect(saw_return_error);
}

test "domain-state body analysis rejects returning root values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\fn leak(take app: AppState) -> AppState:
        \\    return app
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_return_error = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.return")) {
            saw_return_error = true;
            break;
        }
    }
    try std.testing.expect(saw_return_error);

    const leak_item_id = compiler.query.testing.findItemIdByName(&active, "leak").?;
    const leak_body_id = active.semantic_index.itemEntry(leak_item_id).body_id.?;
    const domain_result = try compiler.query.domainStateByBody(&active, leak_body_id);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.rejected_returns);
    try std.testing.expect(domain_result.summary.cfg_edge_count > 0);
    try std.testing.expect(domain_result.summary.effect_site_count > 0);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.lifetime_return_statements_checked);
    try std.testing.expectEqual(@as(usize, 0), domain_result.summary.invalid_cfg_edges);
    try std.testing.expectEqual(@as(usize, 0), domain_result.summary.invalid_effect_sites);
}

test "domain-state body analysis rejects root values passed through boundary calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\#boundary[api]
        \\pub fn export_value[T](take value: T) -> Unit:
        \\    return
        \\
        \\fn use_app(take app: AppState) -> Unit:
        \\    export_value :: app :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const use_item_id = compiler.query.testing.findItemIdByName(&active, "use_app").?;
    const use_body_id = active.semantic_index.itemEntry(use_item_id).body_id.?;
    const domain_result = try compiler.query.domainStateByBody(&active, use_body_id);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.rejected_boundary_arguments);

    var saw_boundary_call = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.boundary_call")) {
            saw_boundary_call = true;
            break;
        }
    }
    try std.testing.expect(saw_boundary_call);
}

test "domain-state body analysis rejects root values passed into task creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\fn spawn[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\fn child(take app: AppState) -> Unit:
        \\    return
        \\
        \\fn launch(take app: AppState) -> Unit:
        \\    spawn :: child, app :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_task_arg = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.task_arg")) {
            saw_task_arg = true;
            break;
        }
    }
    try std.testing.expect(saw_task_arg);

    const launch_item_id = compiler.query.testing.findItemIdByName(&active, "launch").?;
    const launch_body_id = active.semantic_index.itemEntry(launch_item_id).body_id.?;
    const domain_result = try compiler.query.domainStateByBody(&active, launch_body_id);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.rejected_task_arguments);
}

test "domain-state body analysis rejects detached root task creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\fn spawn_detached[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\fn child(take app: AppState) -> Unit:
        \\    return
        \\
        \\fn launch(take app: AppState) -> Unit:
        \\    spawn_detached :: child, app :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_detached_task_arg = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.detached_task_arg")) {
            saw_detached_task_arg = true;
            break;
        }
    }
    try std.testing.expect(saw_detached_task_arg);

    const launch_item_id = compiler.query.testing.findItemIdByName(&active, "launch").?;
    const launch_body_id = active.semantic_index.itemEntry(launch_item_id).body_id.?;
    const domain_result = try compiler.query.domainStateByBody(&active, launch_body_id);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.rejected_detached_task_arguments);
}

test "domain-state body analysis rejects root values passed across suspension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\suspend fn later(take app: AppState) -> Unit:
        \\    return
        \\
        \\suspend fn parent(take app: AppState) -> Unit:
        \\    later :: app :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_suspension_arg = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.suspension_arg")) {
            saw_suspension_arg = true;
            break;
        }
    }
    try std.testing.expect(saw_suspension_arg);

    const parent_item_id = compiler.query.testing.findItemIdByName(&active, "parent").?;
    const parent_body_id = active.semantic_index.itemEntry(parent_item_id).body_id.?;
    const domain_result = try compiler.query.domainStateByBody(&active, parent_body_id);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.rejected_suspensions);
}

test "domain-state body analysis rejects root storage in ordinary aggregates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#domain_root
        \\struct AppState:
        \\    counter: Index
        \\
        \\struct Holder:
        \\    app: AppState
        \\
        \\fn store(take app: AppState) -> Unit:
        \\    let holder: Holder = Holder :: app :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_storage = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.domain_state.storage")) {
            saw_storage = true;
            break;
        }
    }
    try std.testing.expect(saw_storage);

    const store_item_id = compiler.query.testing.findItemIdByName(&active, "store").?;
    const store_body_id = active.semantic_index.itemEntry(store_item_id).body_id.?;
    const domain_result = try compiler.query.domainStateByBody(&active, store_body_id);
    try std.testing.expectEqual(@as(usize, 1), domain_result.summary.rejected_storage);
}

test "checked signatures classify concrete boundary kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\#boundary[value]
        \\pub struct Point:
        \\    x: I32
        \\
        \\#reflect
        \\#boundary[capability]
        \\pub opaque type Handle
        \\
        \\#reflect
        \\#boundary[api]
        \\pub fn ping() -> I32:
        \\    return 7
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const point_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "Point").?);
    try std.testing.expectEqual(compiler.query.BoundaryKind.value, point_sig.boundary_kind);

    const handle_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "Handle").?);
    try std.testing.expectEqual(compiler.query.BoundaryKind.capability, handle_sig.boundary_kind);

    const ping_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "ping").?);
    try std.testing.expectEqual(compiler.query.BoundaryKind.api, ping_sig.boundary_kind);

    const metadata = try compiler.query.collectRuntimeMetadata(std.testing.allocator, &active);
    defer std.testing.allocator.free(metadata);

    var saw_point_non_api = false;
    var saw_ping_api = false;
    for (metadata) |item| {
        if (std.mem.eql(u8, item.name, "Point")) {
            try std.testing.expect(!item.boundary_api);
            saw_point_non_api = true;
        }
        if (std.mem.eql(u8, item.name, "ping")) {
            try std.testing.expect(item.boundary_api);
            saw_ping_api = true;
        }
    }
    try std.testing.expect(saw_point_non_api);
    try std.testing.expect(saw_ping_api);
}

test "checked signatures reject invalid boundary targets and visibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#boundary[api]
        \\fn hidden() -> I32:
        \\    return 1
        \\
        \\#boundary[value]
        \\pub fn bad_value() -> Unit:
        \\    return
        \\
        \\#boundary[capability]
        \\pub struct Wrong:
        \\    value: I32
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_visibility = false;
    var saw_value_target = false;
    var saw_capability_target = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.boundary.visibility")) saw_visibility = true;
        if (std.mem.eql(u8, item.code, "type.boundary.value_target")) saw_value_target = true;
        if (std.mem.eql(u8, item.code, "type.boundary.capability_target")) saw_capability_target = true;
    }

    try std.testing.expect(saw_visibility);
    try std.testing.expect(saw_value_target);
    try std.testing.expect(saw_capability_target);
}

test "checked signatures reject invalid boundary contract types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\pub struct Plain:
        \\    value: Index
        \\
        \\#domain_root
        \\struct Root:
        \\    value: Index
        \\
        \\#boundary[capability]
        \\pub opaque type Handle
        \\
        \\opaque type Task[T]
        \\
        \\#boundary[api]
        \\pub fn bad_api(read borrowed: Index, take task: Task[I32], take plain: Plain) -> Plain:
        \\    return plain
        \\
        \\#boundary[api]
        \\pub fn bad_domain_api(take root: Root) -> I32:
        \\    return 1
        \\
        \\#boundary[value]
        \\pub struct BadValue:
        \\    id: Index
        \\    handle: Handle
        \\    plain: Plain
        \\    root: Root
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_param_mode = false;
    var saw_param_type = false;
    var saw_return_type = false;
    var value_member_errors: usize = 0;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.boundary.api_param_mode")) saw_param_mode = true;
        if (std.mem.eql(u8, item.code, "type.boundary.api_param_type")) saw_param_type = true;
        if (std.mem.eql(u8, item.code, "type.boundary.api_return_type")) saw_return_type = true;
        if (std.mem.eql(u8, item.code, "type.boundary.value_member")) value_member_errors += 1;
    }

    try std.testing.expect(saw_param_mode);
    try std.testing.expect(saw_param_type);
    try std.testing.expect(saw_return_type);
    try std.testing.expectEqual(@as(usize, 3), value_member_errors);
}

test "resolver owns duplicate top-level diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn duplicate() -> I32:
        \\    return 1
        \\
        \\fn duplicate() -> I32:
        \\    return 2
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_duplicate = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "resolve.duplicate")) {
            saw_duplicate = true;
            break;
        }
    }
    try std.testing.expect(saw_duplicate);
}

test "stage0 check accepts suspend bodies and nested suspend calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn later() -> I32:
        \\    return 1
        \\
        \\suspend fn worker() -> I32:
        \\    return later :: :: call
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects direct suspend calls from ordinary functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn later() -> I32:
        \\    return 1
        \\
        \\fn main() -> I32:
        \\    return later :: :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_suspend_context = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.call.suspend_context")) {
            found_suspend_context = true;
            break;
        }
    }
    try std.testing.expect(found_suspend_context);
}

test "stage0 check accepts generic, lifetime, trait, and impl where headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\    fn clone(read self) -> Self
        \\
        \\trait Iterator:
        \\    type Item
        \\
        \\trait Projected[Iter, U]
        \\where Iter: Iterator, Iter.Item = U:
        \\    fn touch(read self) -> Unit
        \\
        \\fn identity[T](take value: T) -> T
        \\where T: Clone:
        \\    return value
        \\
        \\fn borrow_id['a, T](take value: hold['a] read T) -> hold['a] read T
        \\where 'static: 'a, T: 'a:
        \\    return value
        \\
        \\impl[T] Clone for T
        \\where T: Clone:
        \\    fn clone(read self) -> T:
        \\        return self
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects invalid where constraints and unknown lifetimes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Iterator:
        \\    type Item
        \\
        \\fn bad_unknown[T](take value: T) -> T
        \\where U: Iterator:
        \\    return value
        \\
        \\fn bad_projection[Iter, U](take value: U) -> U
        \\where Iter.Item = U:
        \\    return value
        \\
        \\fn bad_lifetime['a, T](take value: hold['a] read T) -> hold['a] read T
        \\where 'b: 'a:
        \\    return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_unknown_name = false;
    var found_invalid_associated = false;
    var found_unknown_lifetime = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.where.unknown_name")) found_unknown_name = true;
        if (std.mem.eql(u8, diagnostic.code, "type.where.associated")) found_invalid_associated = true;
        if (std.mem.eql(u8, diagnostic.code, "type.lifetime.unknown")) found_unknown_lifetime = true;
    }

    try std.testing.expect(found_unknown_name);
    try std.testing.expect(found_invalid_associated);
    try std.testing.expect(found_unknown_lifetime);
}

test "stage0 check accepts generic type declarations with where headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\    fn clone(read self) -> Self
        \\
        \\struct Pair[T]
        \\where T: Clone:
        \\    left: T
        \\    right: T
        \\
        \\enum Maybe[T]
        \\where T: Clone:
        \\    None
        \\    Some(T)
        \\
        \\opaque type Handle[T]
        \\where T: Clone
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects type declaration where names that are not declared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\    fn clone(read self) -> Self
        \\
        \\struct Broken[T]
        \\where U: Clone:
        \\    value: T
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_unknown_name = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.where.unknown_name")) {
            found_unknown_name = true;
            break;
        }
    }
    try std.testing.expect(found_unknown_name);
}

test "stage0 check accepts trait method generic and lifetime headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\    fn clone(read self) -> Self
        \\
        \\trait ViewSource['a, T]
        \\where T: Clone:
        \\    fn view[U](take self: hold['a] read Self, take value: T) -> hold['a] read Self
        \\    where U: Clone, T: 'a
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects broken trait method generic and lifetime headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\    fn clone(read self) -> Self
        \\
        \\trait Broken['a, T]:
        \\    fn view[U](take self: hold['b] read Self, take value: T) -> hold['a] read Self
        \\    where V: Clone, T: 'b
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_unknown_name = false;
    var found_unknown_lifetime = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.where.unknown_name")) found_unknown_name = true;
        if (std.mem.eql(u8, diagnostic.code, "type.lifetime.unknown")) found_unknown_lifetime = true;
    }

    try std.testing.expect(found_unknown_name);
    try std.testing.expect(found_unknown_lifetime);
}

test "stage0 check accepts retained projection returns with outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn get['a, 'b](take box: hold['a] read Box) -> hold['b] read I32
        \\where 'a: 'b:
        \\    return box.value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());

    const get_item_id = compiler.query.testing.findItemIdByName(&active, "get").?;
    const body_id = active.semantic_index.itemEntry(get_item_id).body_id.?;
    const lifetime_result = try compiler.query.lifetimesByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), lifetime_result.summary.return_statements_checked);
    try std.testing.expect(lifetime_result.summary.checked_place_count > 0);
    try std.testing.expect(lifetime_result.summary.cfg_edge_count > 0);
    try std.testing.expect(lifetime_result.summary.effect_site_count > 0);
    try std.testing.expectEqual(@as(usize, 0), lifetime_result.summary.invalid_cfg_edges);
    try std.testing.expectEqual(@as(usize, 0), lifetime_result.summary.invalid_effect_sites);
}

test "stage0 check rejects retained returns without an outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn get['a, 'b](take box: hold['a] read Box) -> hold['b] read I32:
        \\    return box.value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_outlives = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.return.outlives")) {
            found_outlives = true;
            break;
        }
    }
    try std.testing.expect(found_outlives);
}

test "lifetime query propagates retained origins after merged select assignments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn get['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box, take flag: Bool) -> hold['a] read I32:
        \\    let selected: hold['b] read Box = right
        \\    select:
        \\        when flag == true => selected = left
        \\        else => selected = left
        \\    return selected.value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "lifetime.return.outlives"));
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "lifetime.return.retained_source"));
    }

    const get_item_id = compiler.query.testing.findItemIdByName(&active, "get").?;
    const body_id = active.semantic_index.itemEntry(get_item_id).body_id.?;
    const lifetime_result = try compiler.query.lifetimesByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), lifetime_result.summary.return_statements_checked);
    try std.testing.expectEqual(@as(usize, 0), lifetime_result.summary.rejected_returns);
}

test "lifetime query ignores unreachable assignments after branch returns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box, flag: Bool) -> hold['b] read I32:
        \\    let result = right.value
        \\    select:
        \\        when flag == true =>
        \\            return right.value
        \\            result = left.value
        \\        else =>
        \\            result = right.value
        \\    return result
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "lifetime.return.outlives"));
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "lifetime.return.retained_source"));
    }

    const choose_item_id = compiler.query.testing.findItemIdByName(&active, "choose").?;
    const body_id = active.semantic_index.itemEntry(choose_item_id).body_id.?;
    const lifetime_result = try compiler.query.lifetimesByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 2), lifetime_result.summary.return_statements_checked);
    try std.testing.expectEqual(@as(usize, 0), lifetime_result.summary.rejected_returns);
}

test "stage0 check rejects retained returns derived from ephemeral borrows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn leak['a](read value: I32) -> hold['a] read I32:
        \\    return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_ephemeral_source = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.return.ephemeral_source")) {
            found_ephemeral_source = true;
            break;
        }
    }
    try std.testing.expect(found_ephemeral_source);
}

test "stage0 check rejects ephemeral borrow returns across boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn borrow(read value: I32) -> read I32:
        \\    return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_ephemeral_return = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.return.ephemeral")) {
            found_ephemeral_return = true;
            break;
        }
    }
    try std.testing.expect(found_ephemeral_return);
}

test "stage0 check accepts retained call arguments with outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose_shorter['x, 'y](take long: hold['x] read Box, take short: hold['y] read Box) -> I32
        \\where 'x: 'y:
        \\    return short.value
        \\
        \\fn use_boxes['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box) -> I32
        \\where 'a: 'b:
        \\    return choose_shorter :: left, right :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects retained call arguments without an outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose_shorter['x, 'y](take long: hold['x] read Box, take short: hold['y] read Box) -> I32
        \\where 'x: 'y:
        \\    return short.value
        \\
        \\fn use_boxes['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box) -> I32:
        \\    return choose_shorter :: left, right :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_outlives = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.call.outlives")) {
            found_outlives = true;
            break;
        }
    }
    try std.testing.expect(found_outlives);
}

test "stage0 check rejects retained call arguments derived from ephemeral borrows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn keep['a](take value: hold['a] read I32) -> I32:
        \\    return value
        \\
        \\fn use_value(read value: I32) -> I32:
        \\    return keep :: value :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_ephemeral_source = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.call.ephemeral_source")) {
            found_ephemeral_source = true;
            break;
        }
    }
    try std.testing.expect(found_ephemeral_source);
}

test "stage0 check accepts storing retained borrows in constructed values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct BorrowBox['a]:
        \\    value: hold['a] read I32
        \\
        \\fn keep_box['a](take value: hold['a] read I32) -> I32:
        \\    let box = BorrowBox :: value :: call
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects storing retained borrows from ephemeral sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct BorrowBox['a]:
        \\    value: hold['a] read I32
        \\
        \\fn leak_box(read value: I32) -> I32:
        \\    let box: BorrowBox = BorrowBox :: value :: call
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_store_ephemeral = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.store.ephemeral_source")) {
            found_store_ephemeral = true;
            break;
        }
    }
    try std.testing.expect(found_store_ephemeral);
}

test "stage0 check accepts retained self method calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\impl Box:
        \\    fn ping['a](take self: hold['a] read Self) -> I32:
        \\        return 0
        \\
        \\fn use_box['a](take value: hold['a] read Box) -> I32:
        \\    return value.ping :: :: method
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects retained self method calls from ephemeral borrows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\impl Box:
        \\    fn ping['a](take self: hold['a] read Self) -> I32:
        \\        return 0
        \\
        \\fn use_box(read value: Box) -> I32:
        \\    return value.ping :: :: method
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_ephemeral_source = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "lifetime.call.ephemeral_source")) {
            found_ephemeral_source = true;
            break;
        }
    }
    try std.testing.expect(found_ephemeral_source);
}

test "stage0 check accepts region-merged select returns with outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box, flag: Bool) -> hold['b] read I32
        \\where 'a: 'b:
        \\    let result = right.value
        \\    select:
        \\        when flag == true => result = left.value
        \\        else => result = right.value
        \\    return result
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());

    const choose_item_id = compiler.query.testing.findItemIdByName(&active, "choose").?;
    const body_id = active.semantic_index.itemEntry(choose_item_id).body_id.?;
    const region_result = try compiler.query.regionsByBody(&active, body_id);
    try std.testing.expect(region_result.summary.statements_seen > 0);
    try std.testing.expect(region_result.summary.checked_place_count > 0);
    try std.testing.expect(region_result.summary.cfg_edge_count > 0);
    try std.testing.expect(region_result.summary.effect_site_count > 0);
    try std.testing.expectEqual(@as(usize, 0), region_result.summary.invalid_cfg_edges);
    try std.testing.expectEqual(@as(usize, 0), region_result.summary.invalid_effect_sites);
}

test "stage0 check rejects region-merged select returns without an outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box, flag: Bool) -> hold['b] read I32:
        \\    let result = right.value
        \\    select:
        \\        when flag == true => result = left.value
        \\        else => result = right.value
        \\    return result
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_region_outlives = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "region.return.outlives")) {
            found_region_outlives = true;
            break;
        }
    }
    try std.testing.expect(found_region_outlives);
}

test "stage0 check accepts region-merged repeat returns with outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box, flag: Bool) -> hold['b] read I32
        \\where 'a: 'b:
        \\    let result = right.value
        \\    repeat while flag:
        \\        result = left.value
        \\        break
        \\    return result
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects region-merged repeat returns without an outlives proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn choose['a, 'b](take left: hold['a] read Box, take right: hold['b] read Box, flag: Bool) -> hold['b] read I32:
        \\    let result = right.value
        \\    repeat while flag:
        \\        result = left.value
        \\        break
        \\    return result
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_region_outlives = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "region.return.outlives")) {
            found_region_outlives = true;
            break;
        }
    }
    try std.testing.expect(found_region_outlives);
}

test "c abi validation accepts imported unsafe c declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#unsafe
        \\extern["c"] fn puts(value: I32) -> I32
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "c abi validation rejects unsupported conventions and types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\extern["weird"] fn bad(text: Str) -> Bool
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_convention = false;
    var saw_param_type = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "abi.c.convention")) saw_convention = true;
        if (std.mem.eql(u8, diagnostic.code, "abi.c.param_type")) saw_param_type = true;
    }
    try std.testing.expect(saw_convention);
    try std.testing.expect(saw_param_type);
}

test "publication validation rejects unresolved path dependencies" {
    const bad_manifest =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\localdep = { path = "../localdep" }
    ;
    var parsed_bad = try toolchain.package.Manifest.parse(std.testing.allocator, bad_manifest);
    defer parsed_bad.deinit();
    try std.testing.expectError(error.InvalidPublication, toolchain.package.validateManifestForPublication(&parsed_bad));

    const good_manifest =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { version = "1.2.3", registry = "primary" }
        \\
        \\[[products]]
        \\kind = "cdylib"
        \\name = "demo_native"
    ;
    var parsed_good = try toolchain.package.Manifest.parse(std.testing.allocator, good_manifest);
    defer parsed_good.deinit();
    try toolchain.package.validateManifestForPublication(&parsed_good);
    try toolchain.package.validateArtifactPublication(&parsed_good, "demo_native", .cdylib, "x86_64-pc-windows-msvc");
}

test "global store pathing keeps source and artifact identity explicit" {
    var store = try toolchain.package.GlobalStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit(std.testing.allocator);

    var source_id: toolchain.package.SourceIdentity = .{
        .registry = try std.testing.allocator.dupe(u8, "primary"),
        .name = try std.testing.allocator.dupe(u8, "demo"),
        .version = try std.testing.allocator.dupe(u8, "0.1.0"),
    };
    defer source_id.deinit(std.testing.allocator);

    const source_path = try store.pathForSource(std.testing.allocator, source_id);
    defer std.testing.allocator.free(source_path);

    var artifact_id: toolchain.package.ArtifactIdentity = .{
        .registry = try std.testing.allocator.dupe(u8, "primary"),
        .name = try std.testing.allocator.dupe(u8, "demo"),
        .version = try std.testing.allocator.dupe(u8, "0.1.0"),
        .product = try std.testing.allocator.dupe(u8, "demo_native"),
        .kind = .cdylib,
        .target = try std.testing.allocator.dupe(u8, "x86_64-pc-windows-msvc"),
    };
    defer artifact_id.deinit(std.testing.allocator);

    const artifact_path = try store.pathForArtifact(std.testing.allocator, artifact_id);
    defer std.testing.allocator.free(artifact_path);

    try std.testing.expect(std.mem.indexOf(u8, source_path, "\\source\\") != null or std.mem.indexOf(u8, source_path, "/source/") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact_path, "demo_native") != null);
}

test "global store honors RUNA_STORE_ROOT override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const override_root = try std.fs.path.join(std.testing.allocator, &.{ root, "override-store" });
    defer std.testing.allocator.free(override_root);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("RUNA_STORE_ROOT", override_root);

    var store = try toolchain.package.GlobalStore.initWithEnvMap(std.testing.allocator, std.testing.io, &env_map);
    defer store.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(override_root, store.root);
}

test "global store publishes source manifest entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "managed-store" });
    defer std.testing.allocator.free(store_root);

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    var store = try toolchain.package.GlobalStore.initAtRoot(std.testing.allocator, store_root);
    defer store.deinit(std.testing.allocator);

    const published_root = try store.publishSourceManifest(
        std.testing.allocator,
        std.testing.io,
        "primary",
        &loaded.manifest,
        loaded.manifest_path,
        "abc123",
    );
    defer std.testing.allocator.free(published_root);

    try std.Io.Dir.cwd().access(std.testing.io, published_root, .{});
    const manifest_copy = try std.fs.path.join(std.testing.allocator, &.{ published_root, "runa.toml" });
    defer std.testing.allocator.free(manifest_copy);
    const entry_copy = try std.fs.path.join(std.testing.allocator, &.{ published_root, "entry.toml" });
    defer std.testing.allocator.free(entry_copy);
    try std.Io.Dir.cwd().access(std.testing.io, manifest_copy, .{});
    try std.Io.Dir.cwd().access(std.testing.io, entry_copy, .{});
}

test "global store rejects duplicate source publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\ 
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "managed-store" });
    defer std.testing.allocator.free(store_root);

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    var store = try toolchain.package.GlobalStore.initAtRoot(std.testing.allocator, store_root);
    defer store.deinit(std.testing.allocator);

    const first_root = try store.publishSourceManifest(
        std.testing.allocator,
        std.testing.io,
        "primary",
        &loaded.manifest,
        loaded.manifest_path,
        "abc123",
    );
    defer std.testing.allocator.free(first_root);

    try std.testing.expectError(error.AlreadyPublished, store.publishSourceManifest(
        std.testing.allocator,
        std.testing.io,
        "primary",
        &loaded.manifest,
        loaded.manifest_path,
        "abc123",
    ));
}

test "global store publishes built artifact entries" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "cdylib"
        \\name = "demo_native"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data =
        \\#reflect
        \\#boundary[api]
        \\#export[name = "demo_ping"]
        \\pub fn ping() -> I32:
        \\    return 123
        ,
    });

    var build_result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer build_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), build_result.pipeline.diagnostics.errorCount());

    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "managed-store" });
    defer std.testing.allocator.free(store_root);

    var store = try toolchain.package.GlobalStore.initAtRoot(std.testing.allocator, store_root);
    defer store.deinit(std.testing.allocator);

    for (build_result.artifacts.items) |artifact| {
        if (artifact.kind != .cdylib) continue;

        var identity: toolchain.package.ArtifactIdentity = .{
            .registry = try std.testing.allocator.dupe(u8, "primary"),
            .name = try std.testing.allocator.dupe(u8, build_result.workspace.manifest.name.?),
            .version = try std.testing.allocator.dupe(u8, build_result.workspace.manifest.version.?),
            .product = try std.testing.allocator.dupe(u8, artifact.name),
            .kind = artifact.kind,
            .target = try std.testing.allocator.dupe(u8, compiler.target.hostName()),
            .checksum = try std.testing.allocator.dupe(u8, "def456"),
        };
        defer identity.deinit(std.testing.allocator);

        const published_root = try store.publishBuiltArtifact(
            std.testing.allocator,
            std.testing.io,
            identity,
            artifact.path,
            artifact.metadata_path,
        );
        defer std.testing.allocator.free(published_root);

        const artifact_copy = try std.fs.path.join(std.testing.allocator, &.{ published_root, std.fs.path.basename(artifact.path) });
        defer std.testing.allocator.free(artifact_copy);
        const metadata_copy = try std.fs.path.join(std.testing.allocator, &.{ published_root, std.fs.path.basename(artifact.metadata_path) });
        defer std.testing.allocator.free(metadata_copy);
        try std.Io.Dir.cwd().access(std.testing.io, artifact_copy, .{});
        try std.Io.Dir.cwd().access(std.testing.io, metadata_copy, .{});
    }
}

test "publish workflow copies loaded source tree into managed store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const util_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "util" });
    defer std.testing.allocator.free(util_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, util_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\mod util
        \\use util.VALUE
        \\
        \\fn main() -> I32:
        \\    return VALUE
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util/mod.rna",
        .data =
        \\pub(package) const VALUE: I32 = 7
        ,
    });

    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "managed-store" });
    defer std.testing.allocator.free(store_root);

    var published = try toolchain.publish.publishAtPath(std.testing.allocator, std.testing.io, root, "primary", store_root);
    defer published.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), published.copied_source_files);
    try std.testing.expectEqual(@as(usize, 1), published.published_artifacts);

    const root_source = try std.fs.path.join(std.testing.allocator, &.{ published.source_root, "sources", "main.rna" });
    defer std.testing.allocator.free(root_source);
    const child_source = try std.fs.path.join(std.testing.allocator, &.{ published.source_root, "sources", "util", "mod.rna" });
    defer std.testing.allocator.free(child_source);
    try std.Io.Dir.cwd().access(std.testing.io, root_source, .{});
    try std.Io.Dir.cwd().access(std.testing.io, child_source, .{});

    var store = try toolchain.package.GlobalStore.initAtRoot(std.testing.allocator, store_root);
    defer store.deinit(std.testing.allocator);
    var artifact_identity: toolchain.package.ArtifactIdentity = .{
        .registry = try std.testing.allocator.dupe(u8, "primary"),
        .name = try std.testing.allocator.dupe(u8, "demo"),
        .version = try std.testing.allocator.dupe(u8, "0.1.0"),
        .product = try std.testing.allocator.dupe(u8, "demo"),
        .kind = .bin,
        .target = try std.testing.allocator.dupe(u8, compiler.target.hostName()),
        .checksum = null,
    };
    defer artifact_identity.deinit(std.testing.allocator);
    const artifact_root = try store.pathForArtifact(std.testing.allocator, artifact_identity);
    defer std.testing.allocator.free(artifact_root);
    try std.Io.Dir.cwd().access(std.testing.io, artifact_root, .{});
}

test "stage0 check parses a minimal workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const EXIT_CODE: I32 = 7
        \\
        \\fn main() -> I32:
        \\    let value: I32 = EXIT_CODE
        \\    return value
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), pipeline.sourceFileCount());
    try std.testing.expectEqual(@as(usize, 2), pipeline.itemCount());
}

test "query const evaluation handles typed top-level const expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BASE: I32 = 5
        \\const NEXT: I32 = BASE + 3
        \\
        \\fn main() -> I32:
        \\    return NEXT
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
    const value = try compiler.query.testing.evalConstByName(&active, "NEXT");
    try std.testing.expectEqual(@as(i32, 8), value.i32);
}

test "query expressions expose checked conversion facts by expression id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Index:
        \\    const base: U32 = 1
        \\    const signed: I32 = 1
        \\    const widened: Index = base as Index
        \\    signed as may[U32]
        \\    const bad: Bool = base as Bool
        \\    return widened
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_id).body_id.?;
    const result = try compiler.query.expressionsByBody(&active, body_id);

    try std.testing.expectEqual(@as(usize, 3), result.summary.checked_conversion_count);
    try std.testing.expectEqual(@as(usize, 1), result.summary.rejected_conversion_count);
    try std.testing.expectEqual(@as(usize, 3), result.conversion_facts.len);
    try std.testing.expect(result.conversion_facts[0].expression_id.index != result.conversion_facts[1].expression_id.index);

    var saw_rejected_fact = false;
    var saw_checked_fact = false;
    var saw_conversion_diagnostic = false;
    for (result.conversion_facts) |fact| {
        if (fact.status == .rejected and fact.diagnostic_code != null) saw_rejected_fact = true;
        if (fact.mode == .explicit_checked and fact.status == .accepted) saw_checked_fact = true;
    }
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.expr.conversion")) saw_conversion_diagnostic = true;
    }
    try std.testing.expect(saw_rejected_fact);
    try std.testing.expect(saw_checked_fact);
    try std.testing.expect(saw_conversion_diagnostic);
}

test "query const evaluation handles explicit infallible conversions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BASE: U32 = 4
        \\const WIDE: Index = BASE as Index
        \\
        \\fn main() -> Index:
        \\    return WIDE
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const value = try compiler.query.testing.evalConstByName(&active, "WIDE");
    try std.testing.expectEqual(@as(usize, 4), value.index);
}

test "query const evaluation handles checked may conversions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const NEG: I32 = -1
        \\const CHECKED: Result[U32, ConvertError] = NEG as may[U32]
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const value = try compiler.query.testing.evalConstByName(&active, "CHECKED");
    switch (value) {
        .enum_value => |result| {
            try std.testing.expectEqualStrings("Result", result.enum_name);
            try std.testing.expectEqualStrings("Err", result.variant_name);
            try std.testing.expectEqual(@as(usize, 1), result.fields.len);
            switch (result.fields[0].value) {
                .enum_value => |convert_error| {
                    try std.testing.expectEqualStrings("ConvertError", convert_error.enum_name);
                    try std.testing.expectEqualStrings("OutOfRange", convert_error.variant_name);
                },
                else => return error.UnexpectedTestResult,
            }
        },
        else => return error.UnexpectedTestResult,
    }
}

test "query const evaluation rejects invalid compile-time conversions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BASE: U32 = 4
        \\const FLAG: Bool = true
        \\const BAD_CAST: Bool = BASE as Bool
        \\const BAD_CHECKED: Result[U32, ConvertError] = FLAG as may[U32]
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var conversion_diagnostics: usize = 0;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.const.conversion")) conversion_diagnostics += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), conversion_diagnostics);

    const bad_cast_id = compiler.query.testing.findConstIdByName(&active, "BAD_CAST").?;
    const bad_checked_id = compiler.query.testing.findConstIdByName(&active, "BAD_CHECKED").?;
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[bad_cast_id.index].state);
    try std.testing.expect(active.caches.consts[bad_cast_id.index].failed);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.consts[bad_checked_id.index].state);
    try std.testing.expect(active.caches.consts[bad_checked_id.index].failed);
    try std.testing.expectError(error.CachedFailure, compiler.query.constById(&active, bad_cast_id));
    try std.testing.expectError(error.CachedFailure, compiler.query.constById(&active, bad_checked_id));
}

test "query associated const evaluation rejects invalid compile-time conversions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const BASE: U32 = 4
        \\
        \\struct File:
        \\    handle: I32
        \\
        \\impl File:
        \\    const BAD: Bool = BASE as Bool
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_conversion = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.const.conversion")) {
            saw_conversion = true;
            break;
        }
    }
    try std.testing.expect(saw_conversion);

    var impl_const_id: ?compiler.session.AssociatedConstId = null;
    for (active.semantic_index.associated_consts.items, 0..) |entry, index| {
        const item = active.item(entry.item_id);
        const impl_block = switch (item.payload) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };
        if (entry.associated_index >= impl_block.associated_consts.len) continue;
        if (std.mem.eql(u8, impl_block.associated_consts[entry.associated_index].name, "BAD")) {
            impl_const_id = .{ .index = index };
            break;
        }
    }
    try std.testing.expect(impl_const_id != null);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.associated_consts[impl_const_id.?.index].state);
    try std.testing.expect(active.caches.associated_consts[impl_const_id.?.index].failed);
    try std.testing.expectError(error.CachedFailure, compiler.query.associatedConstById(&active, impl_const_id.?));
}

test "query const evaluation handles unary const expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const NEG: I32 = -3
        \\const FLAG: Bool = !false
        \\
        \\fn main() -> I32:
        \\    return NEG
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
    const neg = try compiler.query.testing.evalConstByName(&active, "NEG");
    try std.testing.expectEqual(@as(i32, -3), neg.i32);
    const flag = try compiler.query.testing.evalConstByName(&active, "FLAG");
    try std.testing.expectEqual(true, flag.bool);
}

test "query const evaluation handles modulo and boolean const expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const REM: I32 = 10 % 3
        \\const FLAG: Bool = true && false || true
        \\
        \\fn main() -> I32:
        \\    return REM
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
    const rem = try compiler.query.testing.evalConstByName(&active, "REM");
    try std.testing.expectEqual(@as(i32, 1), rem.i32);
    const flag = try compiler.query.testing.evalConstByName(&active, "FLAG");
    try std.testing.expectEqual(true, flag.bool);
}

test "query const evaluation handles shift and bitwise const expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const MASK: I32 = (~1) & 7
        \\const SHIFTED: I32 = 1 << 3
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
    const mask = try compiler.query.testing.evalConstByName(&active, "MASK");
    try std.testing.expectEqual(@as(i32, 6), mask.i32);
    const shifted = try compiler.query.testing.evalConstByName(&active, "SHIFTED");
    try std.testing.expectEqual(@as(i32, 8), shifted.i32);
}

test "reflection metadata stays exported and opt-in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "cdylib"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data =
        \\#reflect
        \\pub fn visible() -> I32:
        \\    return 1
        \\
        \\fn hidden() -> I32:
        \\    return 2
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());

    const metadata = try compiler.query.collectRuntimeMetadata(std.testing.allocator, &active);
    defer std.testing.allocator.free(metadata);

    try std.testing.expectEqual(@as(usize, 1), metadata.len);
    try std.testing.expectEqualStrings("visible", metadata[0].name);
    try std.testing.expect(metadata[0].runtime_retained);
    const runtime_query = try compiler.query.runtimeReflectionMetadata(&active);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.runtime_reflections.state);
    const runtime_query_again = try compiler.query.runtimeReflectionMetadata(&active);
    try std.testing.expectEqual(runtime_query.metadata.ptr, runtime_query_again.metadata.ptr);

    const module_metadata = try compiler.query.collectModuleRuntimeMetadata(std.testing.allocator, &active, .{ .index = 0 });
    defer std.testing.allocator.free(module_metadata);
    try std.testing.expectEqual(@as(usize, 1), module_metadata.len);
    try std.testing.expectEqualStrings("visible", module_metadata[0].name);
    const module_query = try compiler.query.moduleReflectionMetadata(&active, .{ .index = 0 });
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.module_reflections[0].state);
    const module_query_again = try compiler.query.moduleReflectionMetadata(&active, .{ .index = 0 });
    try std.testing.expectEqual(module_query.metadata.ptr, module_query_again.metadata.ptr);

    const package_id = active.semantic_index.moduleEntry(.{ .index = 0 }).package_id;
    const package_metadata = try compiler.query.collectPackageRuntimeMetadata(std.testing.allocator, &active, package_id);
    defer std.testing.allocator.free(package_metadata);
    try std.testing.expectEqual(@as(usize, 1), package_metadata.len);
    try std.testing.expectEqualStrings("visible", package_metadata[0].name);
    const package_query = try compiler.query.packageReflectionMetadata(&active, package_id);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.package_reflections[package_id.index].state);
    const package_query_again = try compiler.query.packageReflectionMetadata(&active, package_id);
    try std.testing.expectEqual(package_query.metadata.ptr, package_query_again.metadata.ptr);
}

test "reflection metadata reports active query cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\pub const VALUE: I32 = 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expect(try active.pushActiveQuery(.reflection, 0));
    defer active.popActiveQuery();

    try std.testing.expectError(error.QueryCycle, compiler.query.reflectionById(&active, .{ .index = 0 }));

    var saw_reflection_cycle = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.reflection.cycle")) saw_reflection_cycle = true;
    }
    try std.testing.expect(saw_reflection_cycle);
}

test "query reflection metadata records checked declaration shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\pub struct Point[T]:
        \\    pub x: I32
        \\    hidden: Bool
        \\    pub y: T
        \\
        \\#reflect
        \\pub enum Maybe:
        \\    None
        \\    Some(I32)
        \\    Pair:
        \\        left: I32
        \\        right: I32
        \\
        \\#reflect
        \\#boundary[capability]
        \\pub opaque type Handle
        \\
        \\#reflect
        \\pub const LIMIT: I32 = 9
        \\
        \\#reflect
        \\pub fn choose[T](take value: T, read flag: Bool, edit total: I32) -> I32:
        \\    return LIMIT
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const metadata = try compiler.query.collectRuntimeMetadata(std.testing.allocator, &active);
    defer std.testing.allocator.free(metadata);

    var saw_point = false;
    var saw_maybe = false;
    var saw_handle = false;
    var saw_limit = false;
    var saw_choose = false;

    for (metadata) |item| {
        if (std.mem.eql(u8, item.name, "Point")) {
            try std.testing.expectEqual(@as(usize, 3), item.field_count);
            try std.testing.expectEqual(@as(usize, 2), item.public_field_count);
            try std.testing.expectEqual(@as(usize, 2), item.public_fields.len);
            try std.testing.expectEqualStrings("x", item.public_fields[0].name);
            try std.testing.expectEqualStrings("I32", item.public_fields[0].ty.displayName());
            try std.testing.expectEqualStrings("y", item.public_fields[1].name);
            try std.testing.expectEqual(@as(usize, 1), item.generic_param_count);
            saw_point = true;
        } else if (std.mem.eql(u8, item.name, "Maybe")) {
            try std.testing.expectEqual(@as(usize, 3), item.variant_count);
            try std.testing.expectEqual(@as(usize, 3), item.variant_payload_count);
            try std.testing.expectEqual(@as(usize, 3), item.variants.len);
            try std.testing.expectEqualStrings("Some", item.variants[1].name);
            saw_maybe = true;
        } else if (std.mem.eql(u8, item.name, "Handle")) {
            try std.testing.expect(item.opaque_nominal_only);
            try std.testing.expect(item.handle_nominal_only);
            try std.testing.expectEqual(@as(usize, 0), item.public_fields.len);
            try std.testing.expectEqual(@as(usize, 0), item.variants.len);
            saw_handle = true;
        } else if (std.mem.eql(u8, item.name, "LIMIT")) {
            try std.testing.expectEqualStrings("I32", item.const_type_name);
            try std.testing.expect(item.const_value_retained);
            try std.testing.expectEqual(@as(i32, 9), item.const_value.?.i32);
            saw_limit = true;
        } else if (std.mem.eql(u8, item.name, "choose")) {
            try std.testing.expectEqual(@as(usize, 3), item.parameter_count);
            try std.testing.expectEqual(@as(usize, 3), item.parameters.len);
            try std.testing.expectEqualStrings("value", item.parameters[0].name);
            try std.testing.expectEqual(@as(usize, 1), item.take_parameter_count);
            try std.testing.expectEqual(@as(usize, 1), item.read_parameter_count);
            try std.testing.expectEqual(@as(usize, 1), item.edit_parameter_count);
            try std.testing.expectEqualStrings("I32", item.return_type_name);
            try std.testing.expectEqual(@as(usize, 1), item.generic_param_count);
            saw_choose = true;
        }
    }

    try std.testing.expect(saw_point);
    try std.testing.expect(saw_maybe);
    try std.testing.expect(saw_handle);
    try std.testing.expect(saw_limit);
    try std.testing.expect(saw_choose);
}

test "reflection rejects non-exported unsupported and argument-bearing targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\fn hidden() -> I32:
        \\    return 1
        \\
        \\#reflect
        \\pub trait Named:
        \\    fn name(take self: Self) -> Str
        \\
        \\#reflect[full]
        \\pub const VALUE: I32 = 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_exported = false;
    var saw_target = false;
    var saw_args = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.reflect.exported")) saw_exported = true;
        if (std.mem.eql(u8, diagnostic.code, "type.reflect.target")) saw_target = true;
        if (std.mem.eql(u8, diagnostic.code, "type.reflect.args")) saw_args = true;
    }

    try std.testing.expect(saw_exported);
    try std.testing.expect(saw_target);
    try std.testing.expect(saw_args);
}

test "packaged metadata renders reflection and boundary surfaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "cdylib"
        \\name = "demo_native"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data =
        \\#reflect
        \\#boundary[api]
        \\#export[name = "demo_ping"]
        \\pub fn ping() -> I32:
        \\    return 123
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    var metadata = try compiler.metadata.collectPackagedMetadataFromSession(
        std.testing.allocator,
        &active,
        loaded.manifest.name.?,
        loaded.manifest.version.?,
        loaded.products.items[0].name,
        @tagName(loaded.products.items[0].kind),
        0,
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), metadata.reflection.len);
    try std.testing.expectEqual(@as(usize, 1), metadata.boundary_apis.len);
    try std.testing.expectEqualStrings("demo::demo_native::ping", metadata.boundary_apis[0].canonical_identity);
    try std.testing.expectEqualStrings("Unit", metadata.boundary_apis[0].input_type);
    try std.testing.expectEqualStrings("I32", metadata.boundary_apis[0].output_type);

    const rendered = try compiler.metadata.renderDocument(std.testing.allocator, &metadata);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "[[reflection]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[[boundary_apis]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "canonical_identity = \"demo::demo_native::ping\"") != null);

    var parsed = try libraries.std.reflect.parseMetadata(std.testing.allocator, rendered);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("demo", parsed.package_name.?);
    try std.testing.expectEqualStrings("demo_native", parsed.product_name.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.reflection.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.boundary_apis.items.len);
    try std.testing.expectEqualStrings("demo::demo_native::ping", parsed.boundary_apis.items[0].canonical_identity);
}

test "module boundary API metadata is a cached query result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#boundary[api]
        \\#export[name = "demo_ping"]
        \\pub suspend fn ping() -> I32:
        \\    return 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const query_result = try compiler.query.moduleBoundaryApiMetadata(&active, .{ .index = 0 });
    const cached_result = try compiler.query.moduleBoundaryApiMetadata(&active, .{ .index = 0 });
    try std.testing.expectEqual(@as(usize, 1), query_result.apis.len);
    try std.testing.expect(query_result.apis.ptr == cached_result.apis.ptr);
    try std.testing.expectEqualStrings("ping", query_result.apis[0].name);
    try std.testing.expect(query_result.apis[0].is_suspend);
    try std.testing.expectEqualStrings("demo_ping", query_result.apis[0].export_name.?);
}

test "doc and lsp tooling surface reflection and boundary data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "cdylib"
        \\name = "demo_native"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data =
        \\#reflect
        \\#boundary[api]
        \\#export[name = "demo_ping"]
        \\pub fn ping() -> I32:
        \\    return 123
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try compiler.query.finalizeSemanticChecks(&active);

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const doc_output = try toolchain.doc.renderWorkspaceSummary(std.testing.allocator, &loaded, &active);
    defer std.testing.allocator.free(doc_output);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "## Syntax Frontend") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "## Runtime Reflection") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "## Boundary APIs") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "demo::demo_native::ping") != null);

    const index = toolchain.lsp.buildIndex(&active.pipeline);
    try std.testing.expectEqual(@as(usize, 1), index.symbols);
    try std.testing.expectEqual(@as(usize, 1), index.exported_items);
    try std.testing.expectEqual(@as(usize, 1), index.reflectable_items);
    try std.testing.expectEqual(@as(usize, 1), index.boundary_apis);
    try std.testing.expect(index.syntax_tokens != 0);
    try std.testing.expect(index.cst_nodes != 0);
}

test "stage0 doc renders struct fields from typed declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\pub struct Point:
        \\    x: I32
        \\    pub y: I32
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try compiler.query.finalizeSemanticChecks(&active);

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const doc_output = try toolchain.doc.renderWorkspaceSummary(std.testing.allocator, &loaded, &active);
    defer std.testing.allocator.free(doc_output);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "`struct_type` `Point`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "field `x`: `I32`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "field `y`: `I32`") != null);

    const index = toolchain.lsp.buildIndex(&active.pipeline);
    try std.testing.expectEqual(@as(usize, 1), index.type_items);
    try std.testing.expectEqual(@as(usize, 2), index.struct_fields);
}

test "stage0 check rejects duplicate struct fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    x: I32
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 check accepts declared type references in fields and payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\
        \\struct Wrapper:
        \\    point: Point
        \\
        \\enum MaybePoint:
        \\    None
        \\    Some(Point)
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
}

test "stage0 check rejects unknown declaration type references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Wrapper:
        \\    point: MissingType
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 doc renders enum variants from typed declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\pub enum Maybe:
        \\    None
        \\    Some(I32)
        \\    Pair:
        \\        left: I32
        \\        right: I32
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try compiler.query.finalizeSemanticChecks(&active);

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const doc_output = try toolchain.doc.renderWorkspaceSummary(std.testing.allocator, &loaded, &active);
    defer std.testing.allocator.free(doc_output);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "`enum_type` `Maybe`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "variant `None`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "variant `Some(I32)`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "variant `Pair`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "field `left`: `I32`") != null);

    const index = toolchain.lsp.buildIndex(&active.pipeline);
    try std.testing.expectEqual(@as(usize, 1), index.type_items);
    try std.testing.expectEqual(@as(usize, 3), index.enum_variants);
}

test "stage0 doc renders boundary-only union fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#repr[c]
        \\pub union NumberBits:
        \\    i: I32
        \\    u: U32
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try compiler.query.finalizeSemanticChecks(&active);

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const doc_output = try toolchain.doc.renderWorkspaceSummary(std.testing.allocator, &loaded, &active);
    defer std.testing.allocator.free(doc_output);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "`union_type` `NumberBits`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "union field `i`: `I32`") != null);

    const index = toolchain.lsp.buildIndex(&active.pipeline);
    try std.testing.expectEqual(@as(usize, 1), index.type_items);
    try std.testing.expectEqual(@as(usize, 2), index.union_fields);
}

test "stage0 check rejects union without repr c" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\union NumberBits:
        \\    i: I32
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 doc renders trait members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\pub trait Cursor:
        \\    type Item
        \\    fn next(edit self) -> I32
        \\    suspend fn refill(edit self) -> Unit:
        \\        ...
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try compiler.query.finalizeSemanticChecks(&active);

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const doc_output = try toolchain.doc.renderWorkspaceSummary(std.testing.allocator, &loaded, &active);
    defer std.testing.allocator.free(doc_output);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "`trait_type` `Cursor`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "associated type `Item`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "method `next`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "suspend method `refill` with default body") != null);

    const index = toolchain.lsp.buildIndex(&active.pipeline);
    try std.testing.expectEqual(@as(usize, 1), index.trait_items);
    try std.testing.expectEqual(@as(usize, 2), index.trait_methods);
    try std.testing.expectEqual(@as(usize, 1), index.associated_types);
}

test "stage0 check rejects opaque type body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\opaque type Handle:
        \\    value: I32
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 doc renders impl blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Window:
        \\    width: I32
        \\
        \\trait Reset:
        \\    fn reset(edit self) -> Unit
        \\
        \\impl Window:
        \\    fn resize(edit self) -> Unit:
        \\        ...
        \\
        \\impl Reset for Window:
        \\    fn reset(edit self) -> Unit:
        \\        ...
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var loaded = try toolchain.workspace.loadAtPath(std.testing.allocator, std.testing.io, root);
    defer loaded.deinit();

    const roots = try collectRootPaths(std.testing.allocator, loaded.products.items);
    defer std.testing.allocator.free(roots);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, roots);
    defer active.deinit();
    try compiler.query.finalizeSemanticChecks(&active);

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const doc_output = try toolchain.doc.renderWorkspaceSummary(std.testing.allocator, &loaded, &active);
    defer std.testing.allocator.free(doc_output);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "inherent impl for `Window`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "impl `Reset` for `Window`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "method `resize` with body") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_output, "method `reset` with body") != null);

    const index = toolchain.lsp.buildIndex(&active.pipeline);
    try std.testing.expectEqual(@as(usize, 2), index.impl_items);
    try std.testing.expectEqual(@as(usize, 2), index.impl_methods);
}

test "stage0 check rejects impl block with unknown target type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\impl Missing:
        \\    fn run(edit self) -> Unit:
        \\        ...
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 formatter rewrites current subset deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#reflect
        \\pub fn main() -> I32:
        \\  return  7
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());

    const result = try toolchain.fmt.formatPipeline(std.testing.allocator, std.testing.io, pipeline, true);
    try std.testing.expectEqual(@as(usize, 1), result.formatted_files);
    try std.testing.expectEqual(@as(usize, 1), result.changed_files);

    const rewritten = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(rewritten);
    try std.testing.expectEqualStrings(
        \\#reflect
        \\pub fn main() -> I32:
        \\    return  7
        \\
    , rewritten);
}

test "stage0 build emits windows exe and dll artifacts" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        \\
        \\[[products]]
        \\kind = "cdylib"
        \\name = "demo_native"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn answer() -> I32:
        \\    return 7
        \\
        \\fn main() -> I32:
        \\    let value: I32 = answer :: :: call
        \\    return value + 1
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib.rna",
        .data =
        \\#reflect
        \\#boundary[api]
        \\#export[name = "demo_ping"]
        \\pub fn ping() -> I32:
        \\    return 123
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 2), result.artifacts.items.len);
    try std.testing.expect(result.workspace.lockfile != null);
    try std.testing.expectEqual(@as(usize, 1), result.workspace.lockfile.?.sources.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.workspace.lockfile.?.artifacts.items.len);
    for (result.artifacts.items) |artifact| {
        try std.Io.Dir.cwd().access(std.testing.io, artifact.path, .{});
        try std.Io.Dir.cwd().access(std.testing.io, artifact.c_path, .{});
        try std.Io.Dir.cwd().access(std.testing.io, artifact.metadata_path, .{});

        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        const metadata_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.metadata_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(metadata_source);

        switch (artifact.kind) {
            .bin => {
                try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_answer") != null);
                try std.testing.expect(std.mem.indexOf(u8, c_source, "return runa_fn_main();") != null);
                try std.testing.expect(std.mem.indexOf(u8, metadata_source, "product = \"demo_app\"") != null);

                const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
                    .argv = &.{artifact.path},
                    .cwd = .inherit,
                });
                defer std.testing.allocator.free(run_result.stdout);
                defer std.testing.allocator.free(run_result.stderr);

                switch (run_result.term) {
                    .exited => |code| try std.testing.expectEqual(@as(u8, 8), code),
                    else => return error.UnexpectedTestResult,
                }
            },
            .cdylib => {
                try std.testing.expect(std.mem.indexOf(u8, c_source, "demo_ping") != null);
                try std.testing.expect(std.mem.indexOf(u8, metadata_source, "[[reflection]]") != null);
                try std.testing.expect(std.mem.indexOf(u8, metadata_source, "[[boundary_apis]]") != null);
                try std.testing.expect(std.mem.indexOf(u8, metadata_source, "export_name = \"demo_ping\"") != null);
            },
            .lib => unreachable,
        }
    }
}

test "runtime leafs own entry and abort code generation" {
    const wrapper_i32 = try compiler.runtime.entry.renderMainWrapper(std.testing.allocator, "runa_fn_main", .i32);
    defer std.testing.allocator.free(wrapper_i32);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_i32, "return runa_fn_main();") != null);

    const wrapper_unit = try compiler.runtime.entry.renderMainWrapper(std.testing.allocator, "runa_fn_main", .unit);
    defer std.testing.allocator.free(wrapper_unit);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_unit, "runa_fn_main();") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_unit, "return 0;") != null);

    const abort_support = try compiler.runtime.abort.renderAbortSupport(std.testing.allocator);
    defer std.testing.allocator.free(abort_support);
    try std.testing.expect(std.mem.indexOf(u8, abort_support, "runa_abort") != null);
    try std.testing.expect(std.mem.indexOf(u8, abort_support, "abort();") != null);
}

test "stage0 build records managed source dependencies in runa.lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { version = "1.2.3", registry = "primary" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());
    try std.testing.expect(result.workspace.lockfile != null);
    try std.testing.expectEqual(@as(usize, 2), result.workspace.lockfile.?.sources.items.len);
    try std.testing.expectEqualStrings("workspace", result.workspace.lockfile.?.sources.items[0].registry);
    try std.testing.expectEqualStrings("primary", result.workspace.lockfile.?.sources.items[1].registry);
    try std.testing.expectEqualStrings("core", result.workspace.lockfile.?.sources.items[1].name);
    try std.testing.expectEqualStrings("1.2.3", result.workspace.lockfile.?.sources.items[1].version);
}

test "stage0 build emits unary operators" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = -3
        \\    select:
        \\        when !false => return value + 10
        \\        else => return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t value = (-3);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "if ((!false))") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits modulo and boolean operators" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = 10 % 3
        \\    select:
        \\        when true && true || false => return value + 4
        \\        else => return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t value = (10 % 3);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "if (((true && true) || false))") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 5), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits shift and bitwise operators" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = (~1) & 7
        \\    let shifted: I32 = 1 << 3
        \\    let masked: I32 = shifted | value
        \\    return masked ^ 11
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t value = ((~1) & 7);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t shifted = (1 << 3);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return (masked ^ 11);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 5), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits bitwise and shift compound assignment" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = 1
        \\    value <<= 3
        \\    value |= 2
        \\    value ^= 1
        \\    value &= 10
        \\    return value
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "value <<= 3;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "value |= 2;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "value ^= 1;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "value &= 10;") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 10), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check rejects tuple expressions with explicit diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value = (1, 2)
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_tuple = false;
    var found_grouping = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.expr.tuple.stage0")) found_tuple = true;
        if (std.mem.eql(u8, diagnostic.code, "parse.expr.grouping")) found_grouping = true;
    }
    try std.testing.expect(found_tuple);
    try std.testing.expect(!found_grouping);
}

test "semantic rejects array literals without fixed-array context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value = [1, 2]
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_array = false;
    var found_primary = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.expr.array.type")) found_array = true;
        if (std.mem.eql(u8, diagnostic.code, "parse.expr.primary")) found_primary = true;
    }
    try std.testing.expect(found_array);
    try std.testing.expect(!found_primary);
}

test "semantic rejects keyed access on non-array values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    let item = value[0]
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_keyed_access = false;
    var found_primary = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.expr.keyed_access.base")) found_keyed_access = true;
        if (std.mem.eql(u8, diagnostic.code, "parse.expr.primary")) found_primary = true;
    }
    try std.testing.expect(found_keyed_access);
    try std.testing.expect(!found_primary);
}

test "stage0 check rejects tuple projection with explicit diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    let item = value.0
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_projection = false;
    var found_field_syntax = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.expr.tuple_projection.stage0")) found_projection = true;
        if (std.mem.eql(u8, diagnostic.code, "type.field.syntax")) found_field_syntax = true;
    }
    try std.testing.expect(found_projection);
    try std.testing.expect(!found_field_syntax);
}

test "stage0 check rejects comparison chaining" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let flag: Bool = 1 < 2 < 3
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_chain = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.expr.compare_chain")) {
            found_chain = true;
            break;
        }
    }
    try std.testing.expect(found_chain);
}

test "stage0 check accepts bare function-value formation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn add_one(take x: I32) -> I32:
        \\    return x + 1
        \\
        \\fn main() -> Unit:
        \\    let f = add_one
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
}

test "stage0 check rejects borrowed function-value formation with explicit diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn inspect(read value: I32) -> I32:
        \\    return value
        \\
        \\fn main() -> Unit:
        \\    let f = inspect
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_borrow = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.callable.function_value.borrow")) {
            found_borrow = true;
            break;
        }
    }
    try std.testing.expect(found_borrow);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const callable_result = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_function_value_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.rejected_borrow_parameter_function_values);
}

test "query callable checks reject generic function-value formation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn identity[T](take value: T) -> T:
        \\    return value
        \\
        \\fn main() -> Unit:
        \\    let f = identity
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_generic = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.callable.function_value.generic")) {
            found_generic = true;
            break;
        }
    }
    try std.testing.expect(found_generic);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const callable_result = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_function_value_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.rejected_generic_function_values);
}

test "stage0 check accepts local callable dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn add_one(take x: I32) -> I32:
        \\    return x + 1
        \\
        \\fn main() -> Unit:
        \\    let f = add_one
        \\    let value = f :: 41 :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const callable_result = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_function_value_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_dispatch_count);
}

test "query callable checks reject non-callable local dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    let result = value :: 2 :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_dispatch = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.callable.dispatch")) {
            found_dispatch = true;
            break;
        }
    }
    try std.testing.expect(found_dispatch);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const callable_result = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_dispatch_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.rejected_dispatch_count);
    const callable_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(callable_diagnostic_count, active.pipeline.diagnostics.items.items.len);
}

test "query callable checks reject callable-value arity and argument types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn add_one(take x: I32) -> I32:
        \\    return x + 1
        \\
        \\fn main() -> Unit:
        \\    let f = add_one
        \\    let missing = f :: :: call
        \\    let wrong = f :: true :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_arity = false;
    var found_arg = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.callable.arity")) found_arity = true;
        if (std.mem.eql(u8, diagnostic.code, "type.callable.arg")) found_arg = true;
    }
    try std.testing.expect(found_arity);
    try std.testing.expect(found_arg);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const callable_result = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 2), callable_result.summary.checked_dispatch_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.rejected_arity_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.rejected_arg_count);
}

test "stage0 check accepts tuple-packed function-value dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn add(take left: I32, take right: I32) -> I32:
        \\    return left + right
        \\
        \\fn main() -> Unit:
        \\    let f = add
        \\    let value = f :: 20, 22 :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const callable_result = try compiler.query.callablesByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_function_value_count);
    try std.testing.expectEqual(@as(usize, 1), callable_result.summary.checked_dispatch_count);
    try std.testing.expectEqual(@as(usize, 0), callable_result.summary.rejected_arity_count);
    try std.testing.expectEqual(@as(usize, 0), callable_result.summary.rejected_arg_count);
}

test "stage0 build emits local callable dispatch" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_callable"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn add_one(take x: I32) -> I32:
        \\    return x + 1
        \\
        \\fn main() -> I32:
        \\    let f = add_one
        \\    return f :: 41 :: call
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t (*f)(int32_t) = runa_fn_add_one;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return f(41);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 42), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits tuple-packed callable dispatch" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_callable_tuple"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn add(take left: I32, take right: I32) -> I32:
        \\    return left + right
        \\
        \\fn main() -> I32:
        \\    let f = add
        \\    return f :: 20, 22 :: call
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t (*f)(int32_t, int32_t) = runa_fn_add;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return f(20, 22);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 42), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "semantic rejects overlapping marker impls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Marker:
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Marker for Counter:
        \\
        \\impl Marker for Counter:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_overlap = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.overlap")) {
            found_overlap = true;
            break;
        }
    }
    try std.testing.expect(found_overlap);
}

test "semantic distinguishes concrete generic impl heads for overlap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Marker:
        \\
        \\struct Box[T]:
        \\    value: T
        \\
        \\impl Marker for Box[I32]:
        \\
        \\impl Marker for Box[U32]:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
}

test "semantic rejects generic impl overlap with concrete application" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Marker:
        \\
        \\struct Box[T]:
        \\    value: T
        \\
        \\impl [T] Marker for Box[T]:
        \\
        \\impl Marker for Box[I32]:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_overlap = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.overlap")) {
            found_overlap = true;
            break;
        }
    }
    try std.testing.expect(found_overlap);
}

test "semantic rejects user-written Send impls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Send:
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Send for Counter:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_send_impl = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.send_builtin")) {
            found_send_impl = true;
            break;
        }
    }
    try std.testing.expect(found_send_impl);
}

test "semantic rejects orphan impls for imported trait and type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Marker
        \\use core.Counter
        \\
        \\impl Marker for Counter:
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub trait Marker:
        \\
        \\pub struct Counter:
        \\    value: I32
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    var found_orphan = false;
    for (result.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.orphan")) {
            found_orphan = true;
            break;
        }
    }
    try std.testing.expect(found_orphan);
}

test "semantic accepts trait impl associated type binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Iterator:
        \\    type Item
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Iterator for Counter:
        \\    type Item = I32
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), active.semantic_index.impls.items.len);
    const impl_id = compiler.session.ImplId{ .index = 0 };
    const impl_item = active.item(active.semantic_index.implEntry(impl_id).item_id);
    try std.testing.expectEqual(@as(usize, 1), impl_item.payload.impl_block.associated_types.len);
    try std.testing.expectEqualStrings("Item", impl_item.payload.impl_block.associated_types[0].name);
    try std.testing.expectEqualStrings("I32", impl_item.payload.impl_block.associated_types[0].value_type_name);
}

test "semantic rejects missing trait impl associated type binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Iterator:
        \\    type Item
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Iterator for Counter:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_missing = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.associated_missing")) {
            found_missing = true;
            break;
        }
    }
    try std.testing.expect(found_missing);
}

test "semantic rejects unknown trait impl associated type binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Marker:
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Marker for Counter:
        \\    type Item = I32
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_unknown = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.associated_unknown")) {
            found_unknown = true;
            break;
        }
    }
    try std.testing.expect(found_unknown);
}

test "semantic accepts trait impl associated const binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Blocked:
        \\    const BLOCK_SIZE: Index
        \\
        \\struct File:
        \\    handle: I32
        \\
        \\impl Blocked for File:
        \\    const BLOCK_SIZE: Index = 4096
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 2), active.associatedConstCount());

    const trait_sig = try compiler.query.checkedSignature(&active, compiler.query.testing.findItemIdByName(&active, "Blocked").?);
    switch (trait_sig.facts) {
        .trait_type => |signature| {
            try std.testing.expectEqual(@as(usize, 1), signature.associated_consts.len);
            try std.testing.expectEqualStrings("BLOCK_SIZE", signature.associated_consts[0].name);
            try std.testing.expectEqualStrings("Index", signature.associated_consts[0].type_name);
        },
        else => return error.UnexpectedTestResult,
    }

    var impl_const_id: ?compiler.session.AssociatedConstId = null;
    for (active.semantic_index.associated_consts.items, 0..) |entry, index| {
        const item = active.item(entry.item_id);
        const impl_block = switch (item.payload) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };
        if (entry.associated_index >= impl_block.associated_consts.len) continue;
        if (std.mem.eql(u8, impl_block.associated_consts[entry.associated_index].name, "BLOCK_SIZE")) {
            impl_const_id = .{ .index = index };
            break;
        }
    }
    const value = try compiler.query.associatedConstById(&active, impl_const_id.?);
    try std.testing.expectEqual(@as(usize, 4096), value.value.index);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.associated_consts[impl_const_id.?.index].state);
}

test "semantic rejects missing trait impl associated const binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Blocked:
        \\    const BLOCK_SIZE: Index
        \\
        \\struct File:
        \\    handle: I32
        \\
        \\impl Blocked for File:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_missing = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.associated_const_missing")) {
            found_missing = true;
            break;
        }
    }
    try std.testing.expect(found_missing);
}

test "semantic rejects unknown trait impl associated const binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Marker:
        \\
        \\struct File:
        \\    handle: I32
        \\
        \\impl Marker for File:
        \\    const BLOCK_SIZE: Index = 4096
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_unknown = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.associated_const_unknown")) {
            found_unknown = true;
            break;
        }
    }
    try std.testing.expect(found_unknown);
}

test "query const evaluation resolves inherent associated consts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum TokenKind:
        \\    Word
        \\
        \\impl TokenKind:
        \\    const COUNT: Index = 1
        \\
        \\const VALUE: Index = TokenKind.COUNT
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const value = try compiler.query.testing.evalConstByName(&active, "VALUE");
    try std.testing.expectEqual(@as(usize, 1), value.index);
}

test "query const evaluation caches associated const cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum TokenKind:
        \\    Word
        \\
        \\impl TokenKind:
        \\    const A: Index = TokenKind.B
        \\    const B: Index = TokenKind.A
        \\
        \\const VALUE: Index = TokenKind.A
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_cycle = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.const.cycle")) {
            found_cycle = true;
            break;
        }
    }
    try std.testing.expect(found_cycle);
}

test "query const evaluation diagnoses ambiguous associated const lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait A:
        \\    const SIZE: Index
        \\
        \\trait B:
        \\    const SIZE: Index
        \\
        \\struct File:
        \\    handle: I32
        \\
        \\impl A for File:
        \\    const SIZE: Index = 1
        \\
        \\impl B for File:
        \\    const SIZE: Index = 2
        \\
        \\const VALUE: Index = File.SIZE
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_ambiguous = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.const.associated_ambiguous")) {
            found_ambiguous = true;
            break;
        }
    }
    try std.testing.expect(found_ambiguous);
}

test "trait solver reports default inheritance and associated projection equality" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Iterator:
        \\    type Item
        \\
        \\trait Reset:
        \\    fn reset(take self) -> I32:
        \\        return self.value
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Iterator for Counter:
        \\    type Item = I32
        \\
        \\impl Reset for Counter:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), active.associatedTypeCount());
    const counter_id = compiler.query.testing.findItemIdByName(&active, "Counter").?;
    const module_id = active.semantic_index.itemEntry(counter_id).module_id;

    const reset = try satisfiesTraitForTest(&active, module_id, "Counter", "Reset", &.{});
    try std.testing.expect(reset.satisfied);
    try std.testing.expectEqual(@as(usize, 1), reset.inherited_default_method_count);
    const trait_goal_count = active.caches.trait_goals.items.len;
    const impl_lookup_count = active.caches.impl_lookups.items.len;
    const impl_index_entries = active.caches.impl_index.value.?.entries.len;
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.impl_index.state);
    try std.testing.expectEqual(@as(usize, 2), impl_index_entries);
    const reset_again = try satisfiesTraitForTest(&active, module_id, "Counter", "Reset", &.{});
    try std.testing.expect(reset_again.satisfied);
    try std.testing.expectEqual(trait_goal_count, active.caches.trait_goals.items.len);
    try std.testing.expectEqual(impl_lookup_count, active.caches.impl_lookups.items.len);
    try std.testing.expectEqual(impl_index_entries, active.caches.impl_index.value.?.entries.len);

    const associated_lookup_count = active.caches.impl_lookups.items.len;
    try std.testing.expect(try associatedTypeEqualsForTest(&active, module_id, "Counter", "Iterator", "Item", "I32", &.{}));
    const associated_lookup_count_after = active.caches.impl_lookups.items.len;
    try std.testing.expect(associated_lookup_count_after >= associated_lookup_count);
    try std.testing.expect(!try associatedTypeEqualsForTest(&active, module_id, "Counter", "Iterator", "Item", "U32", &.{}));
    try std.testing.expectEqual(associated_lookup_count_after, active.caches.impl_lookups.items.len);
    try std.testing.expectEqual(impl_index_entries, active.caches.impl_index.value.?.entries.len);
}

test "trait impl lookup demands checked signatures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Reset:
        \\    fn reset(take self) -> I32:
        \\        return self.value
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const counter_id = compiler.query.testing.findItemIdByName(&active, "Counter").?;
    const module_id = active.semantic_index.itemEntry(counter_id).module_id;
    try std.testing.expectEqual(compiler.session.QueryState.not_started, active.caches.signatures[counter_id.index].state);

    const result = try satisfiesTraitForTest(&active, module_id, "Counter", "Reset", &.{});
    try std.testing.expect(result.satisfied);
    try std.testing.expectEqual(@as(usize, 1), result.inherited_default_method_count);
    try std.testing.expectEqual(compiler.session.QueryState.complete, active.caches.impl_index.state);
    try std.testing.expectEqual(@as(usize, 1), active.caches.impl_index.value.?.entries.len);

    var saw_checked_impl = false;
    for (active.semantic_index.impls.items) |impl_entry| {
        if (active.caches.signatures[impl_entry.item_id.index].state == .complete) saw_checked_impl = true;
    }
    try std.testing.expect(saw_checked_impl);
}

test "trait solver selects generic impls for concrete self types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\
        \\trait Reset:
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Clone for Counter:
        \\
        \\impl [T] Reset for T
        \\where T: Clone:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const counter_id = compiler.query.testing.findItemIdByName(&active, "Counter").?;
    const module_id = active.semantic_index.itemEntry(counter_id).module_id;

    const result = try satisfiesTraitForTest(&active, module_id, "Counter", "Reset", &.{});
    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.impl_id != null);
}

test "trait solver substitutes generic impl target arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Clone:
        \\
        \\trait Reset:
        \\
        \\trait Iterable:
        \\    type Item
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\struct Box[T]:
        \\    value: T
        \\
        \\impl Clone for Counter:
        \\
        \\impl [T] Reset for Box[T]
        \\where T: Clone:
        \\
        \\impl [T] Iterable for Box[T]:
        \\    type Item = T
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const box_id = compiler.query.testing.findItemIdByName(&active, "Box").?;
    const module_id = active.semantic_index.itemEntry(box_id).module_id;

    const boxed_counter = try satisfiesTraitForTest(&active, module_id, "Box[Counter]", "Reset", &.{});
    try std.testing.expect(boxed_counter.satisfied);

    const boxed_i32 = try satisfiesTraitForTest(&active, module_id, "Box[I32]", "Reset", &.{});
    try std.testing.expect(!boxed_i32.satisfied);

    try std.testing.expect(try associatedTypeEqualsForTest(&active, module_id, "Box[Counter]", "Iterable", "Item", "Counter", &.{}));
    try std.testing.expect(!try associatedTypeEqualsForTest(&active, module_id, "Box[Counter]", "Iterable", "Item", "I32", &.{}));
}

test "trait solver satisfies builtin Send from where environment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const module_id = active.semantic_index.itemEntry(main_id).module_id;
    const where_env = [_]compiler.typed.WherePredicate{
        .{ .bound = .{
            .subject_name = "T",
            .contract_name = "Send",
        } },
    };

    const result = try satisfiesTraitForTest(&active, module_id, "T", "Send", &where_env);
    try std.testing.expect(result.satisfied);
}

test "trait solver reports cycles through shared query diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const main_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const module_id = active.semantic_index.itemEntry(main_id).module_id;
    const result = try satisfiesTraitForTest(&active, module_id, "I32", "Send", &.{});
    try std.testing.expect(result.satisfied);
    const goal_index = active.caches.trait_goals.items.len - 1;
    active.caches.trait_goals.items[goal_index].state = .in_progress;

    try std.testing.expectError(error.QueryCycle, satisfiesTraitForTest(&active, module_id, "I32", "Send", &.{}));

    var saw_trait_cycle = false;
    for (active.pipeline.diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, "type.trait.cycle")) saw_trait_cycle = true;
    }
    try std.testing.expect(saw_trait_cycle);
}

test "semantic rejects non-Send worker spawn input but allows local spawn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\opaque type Task[T]
        \\
        \\suspend fn child(take task: Task[I32]) -> I32:
        \\    return 1
        \\
        \\fn spawn[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\fn spawn_local[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\suspend fn launch(take task: Task[I32]) -> Unit:
        \\    spawn :: child, task :: call
        \\    spawn_local :: child, task :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var send_input_errors: usize = 0;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.send.spawn_input")) send_input_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), send_input_errors);
}

test "semantic accepts worker spawn input constrained by Send where environment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn child[T](take value: T) -> I32
        \\where T: Send:
        \\    return 1
        \\
        \\fn spawn[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\fn launch[T](take value: T) -> Unit
        \\where T: Send:
        \\    spawn :: child, value :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "type.send.spawn_input"));
    }
}

test "semantic rejects non-Send worker spawn output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\opaque type Task[T]
        \\
        \\suspend fn child(take task: Task[I32]) -> Task[I32]:
        \\    return task
        \\
        \\fn spawn[F, In, Out](take f: F, take input: In) -> Unit:
        \\    return
        \\
        \\suspend fn launch(take task: Task[I32]) -> Unit:
        \\    spawn :: child, task :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_send_output = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.send.spawn_output")) {
            found_send_output = true;
            break;
        }
    }
    try std.testing.expect(found_send_output);
}

test "stage0 codegen emits defer cleanup before return" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn cleanup() -> Unit:
        \\    ...
        \\
        \\fn main() -> I32:
        \\    defer cleanup :: :: call
        \\    return 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        const cleanup_call = std.mem.indexOf(u8, c_source, "runa_fn_cleanup();") orelse return error.ExpectedTestFailure;
        const return_stmt = std.mem.indexOf(u8, c_source, "return 1;") orelse return error.ExpectedTestFailure;
        try std.testing.expect(cleanup_call < return_stmt);
    }
}

test "stage0 build emits guarded select control flow" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let flag: Bool = true
        \\    select:
        \\        when flag == true => return 7
        \\        else => return 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "if ((flag == true))") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "else {") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits block-bodied select arms" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    select:
        \\        when true =>
        \\            let value: I32 = 6
        \\            return value + 1
        \\        else =>
        \\            return 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t value = 6;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return (value + 1);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits subject select with literal patterns" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let code: I32 = 4
        \\    select code:
        \\        when 3 => return 1
        \\        when 4 => return 8
        \\        else => return 2
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "if ((runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "== 3))") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "== 4))") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 8), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits subject select with binding patterns" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let code: I32 = 6
        \\    select code:
        \\        when value =>
        \\            return value + 2
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "const int32_t value = runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return (value + 2);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 8), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits subject select for computed expressions" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn code() -> I32:
        \\    return 4
        \\
        \\fn main() -> I32:
        \\    select (code :: :: call) + 0:
        \\        when 3 => return 1
        \\        when 4 => return 9
        \\        else => return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "int32_t runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_code()") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "if ((runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "== 4))") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 codegen emits nested defer cleanup inside select arm blocks" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn cleanup() -> Unit:
        \\    return
        \\
        \\fn main() -> I32:
        \\    select:
        \\        when true =>
        \\            defer cleanup :: :: call
        \\            return 9
        \\        else =>
        \\            return 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        const cleanup_call = std.mem.indexOf(u8, c_source, "runa_fn_cleanup();") orelse return error.ExpectedTestFailure;
        const return_stmt = std.mem.indexOf(u8, c_source, "return 9;") orelse return error.ExpectedTestFailure;
        try std.testing.expect(cleanup_call < return_stmt);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits repeat while with break" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn cleanup() -> Unit:
        \\    return
        \\
        \\fn main() -> I32:
        \\    repeat while true:
        \\        defer cleanup :: :: call
        \\        break
        \\    return 5
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "while (true)") != null);
        const cleanup_call = std.mem.indexOf(u8, c_source, "runa_fn_cleanup();") orelse return error.ExpectedTestFailure;
        const break_stmt = std.mem.indexOf(u8, c_source, "break;") orelse return error.ExpectedTestFailure;
        try std.testing.expect(cleanup_call < break_stmt);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 5), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits repeat while with continue" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn cleanup() -> Unit:
        \\    return
        \\
        \\fn main() -> I32:
        \\    repeat while false:
        \\        defer cleanup :: :: call
        \\        continue
        \\    return 3
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "while (false)") != null);
        const cleanup_call = std.mem.indexOf(u8, c_source, "runa_fn_cleanup();") orelse return error.ExpectedTestFailure;
        const continue_stmt = std.mem.indexOf(u8, c_source, "continue;") orelse return error.ExpectedTestFailure;
        try std.testing.expect(cleanup_call < continue_stmt);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
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

test "stage0 check rejects non-iterable repeat iteration without generic statement fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    repeat item in value:
        \\        break
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_iterable = false;
    var found_generic_statement = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.repeat.iterable")) found_iterable = true;
        if (std.mem.eql(u8, diagnostic.code, "type.stage0.statement")) found_generic_statement = true;
    }
    try std.testing.expect(found_iterable);
    try std.testing.expect(!found_generic_statement);
}

test "query repeat iteration rejects named types without Iterable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Bag:
        \\    value: I32
        \\
        \\fn main() -> Unit:
        \\    let bag: Bag = Bag :: 1 :: call
        \\    repeat item in bag:
        \\        break
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_iterable = false;
    var found_stage0 = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.repeat.iterable")) found_iterable = true;
        if (std.mem.eql(u8, diagnostic.code, "type.repeat.iteration.stage0")) found_stage0 = true;
    }
    try std.testing.expect(found_iterable);
    try std.testing.expect(!found_stage0);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const repeat_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.patternsByBody(&active, main_body_id);
    try std.testing.expectEqual(repeat_diagnostic_count, active.pipeline.diagnostics.items.items.len);
}

test "query repeat iteration resolves Iterable through trait facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Iterable:
        \\    type Item
        \\
        \\struct Bag:
        \\    value: I32
        \\
        \\impl Iterable for Bag:
        \\    type Item = I32
        \\
        \\fn main() -> Unit:
        \\    let bag: Bag = Bag :: 1 :: call
        \\    repeat item in bag:
        \\        break
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const pattern_result = try compiler.query.patternsByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), pattern_result.summary.checked_repeat_iteration_count);
    try std.testing.expectEqual(@as(usize, 0), pattern_result.summary.rejected_repeat_iterable_count);
}

test "stage0 check rejects refutable repeat iteration patterns without generic statement fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Maybe:
        \\    None
        \\    Some(I32)
        \\
        \\fn main() -> Unit:
        \\    let value: Maybe = Maybe.Some :: 1 :: call
        \\    repeat Maybe.Some(found) in value:
        \\        break
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_pattern = false;
    var found_generic_statement = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.repeat.pattern")) found_pattern = true;
        if (std.mem.eql(u8, diagnostic.code, "type.stage0.statement")) found_generic_statement = true;
    }
    try std.testing.expect(found_pattern);
    try std.testing.expect(!found_generic_statement);
}

test "stage0 check uses spec diagnostics for tuple subject patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    select value:
        \\        when (left, right) => return
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_tuple_subject = false;
    var found_pattern_stage0 = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.pattern.tuple_subject")) found_tuple_subject = true;
        if (std.mem.eql(u8, diagnostic.code, "type.pattern.stage0")) found_pattern_stage0 = true;
    }
    try std.testing.expect(found_tuple_subject);
    try std.testing.expect(!found_pattern_stage0);
}

test "stage0 check uses spec diagnostics for tuple repeat patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    repeat (left, right) in value:
        \\        break
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_repeat_tuple = false;
    var found_repeat_pattern_stage0 = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.repeat.pattern.tuple")) found_repeat_tuple = true;
        if (std.mem.eql(u8, diagnostic.code, "type.repeat.pattern.stage0")) found_repeat_pattern_stage0 = true;
    }
    try std.testing.expect(found_repeat_tuple);
    try std.testing.expect(!found_repeat_pattern_stage0);
}

test "stage0 build emits local assignment and compound assignment" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = 1
        \\    value = value + 2
        \\    value += 3
        \\    return value + 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "value = (value + 2);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "value += 3;") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check rejects assignment to immutable local const" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> Unit:
        \\    const value: I32 = 1
        \\    value = 2
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 check rejects nested loop binding shadowing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = 1
        \\    repeat while false:
        \\        let value: I32 = 2
        \\    return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_shadow = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "ownership.binding.shadow")) {
            found_shadow = true;
            break;
        }
    }
    try std.testing.expect(found_shadow);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), ownership_result.summary.rejected_bindings);
    try std.testing.expect(ownership_result.summary.checked_place_count > 0);
    try std.testing.expect(ownership_result.summary.cfg_edge_count > 0);
}

test "stage0 check rejects select-arm binding shadowing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let value: I32 = 9
        \\    select:
        \\        when true =>
        \\            let value: I32 = 1
        \\            return value
        \\        else =>
        \\            return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_shadow = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "ownership.binding.shadow")) {
            found_shadow = true;
            break;
        }
    }
    try std.testing.expect(found_shadow);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), ownership_result.summary.rejected_bindings);
    try std.testing.expect(ownership_result.summary.checked_place_count > 0);
    try std.testing.expect(ownership_result.summary.cfg_edge_count > 0);
}

test "ownership query rejects use after take call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn consume(take box: Box) -> Unit:
        \\    return
        \\
        \\fn main() -> Unit:
        \\    let box: Box = Box :: 1 :: call
        \\    consume :: box :: call
        \\    consume :: box :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_move = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "ownership.move_after_take")) {
            found_move = true;
            break;
        }
    }
    try std.testing.expect(found_move);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), ownership_result.summary.move_after_take);
}

test "ownership query keeps mutually exclusive select-arm states independent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn consume(take box: Box) -> Unit:
        \\    return
        \\
        \\fn main() -> I32:
        \\    let flag: Bool = true
        \\    let box: Box = Box :: 1 :: call
        \\    select flag:
        \\        when true =>
        \\            consume :: box :: call
        \\        when false =>
        \\            return box.value
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "ownership.move_after_take"));
    }

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 0), ownership_result.summary.move_after_take);
}

test "ownership query treats break as terminating before later statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn consume(take box: Box) -> Unit:
        \\    return
        \\
        \\fn main() -> Unit:
        \\    let box: Box = Box :: 1 :: call
        \\    repeat while true:
        \\        break
        \\        consume :: box :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "ownership.move_after_take"));
    }

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 0), ownership_result.summary.move_after_take);
}

test "ownership query consumes deferred take at the defer site only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Box:
        \\    value: I32
        \\
        \\fn consume(take box: Box) -> Unit:
        \\    return
        \\
        \\fn main() -> Unit:
        \\    let box: Box = Box :: 1 :: call
        \\    defer consume :: box :: call
        \\    repeat while true:
        \\        break
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.code, "ownership.move_after_take"));
    }

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 0), ownership_result.summary.move_after_take);
}

test "ownership query rejects conflicting same-place call arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn mix(edit left: I32, read right: I32) -> Unit:
        \\    return
        \\
        \\fn main() -> Unit:
        \\    let value: I32 = 1
        \\    mix :: value, value :: call
        \\    return
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var found_conflict = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "ownership.borrow_conflict")) {
            found_conflict = true;
            break;
        }
    }
    try std.testing.expect(found_conflict);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const ownership_result = try compiler.query.ownershipByBody(&active, body_id);
    try std.testing.expectEqual(@as(usize, 1), ownership_result.summary.borrow_conflicts);
}

test "stage0 build emits local struct construction and field projection" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 3, 4 :: call
        \\    return point.x + point.y
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_Point") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "point = ((runa_type_Point){3, 4});") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "((point.x) + (point.y))") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local struct field assignment" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 1, 2 :: call
        \\    point.x = 4
        \\    point.y += 3
        \\    return point.x + point.y
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "point.x = 4;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "point.y += 3;") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local inherent take-self methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\impl Point:
        \\    fn total(take self, extra: I32) -> I32:
        \\        return self.x + self.y + extra
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 2, 3 :: call
        \\    return point.total :: 4 :: method
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Point__total(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Point__total(point, 4)") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build lowers suspend helpers and suspend inherent methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\
        \\impl Point:
        \\    suspend fn bump(take self) -> I32:
        \\        return self.x + 1
        \\
        \\suspend fn worker() -> I32:
        \\    let point: Point = Point :: 4 :: call
        \\    return point.bump :: :: method
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_worker(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Point__bump(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return runa_fn_Point__bump(point);") != null);
    }
}

test "stage0 build rejects suspend main entry" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\suspend fn main() -> I32:
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    var found_suspend_main = false;
    for (result.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "codegen.main.suspend")) {
            found_suspend_main = true;
            break;
        }
    }
    try std.testing.expect(found_suspend_main);
}

test "stage0 build lowers generic opaque task handles through C emission" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\opaque type Task[T]
        \\
        \\fn pass(task: Task[I32]) -> Task[I32]:
        \\    return task
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_Task") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "void* runa_opaque_handle;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "static runa_type_Task runa_fn_pass(runa_type_Task task);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build lowers exact task await and cancel methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\opaque type Task[T]
        \\
        \\impl Task[I32]:
        \\    suspend fn await(take self) -> I32:
        \\        return 7
        \\
        \\    suspend fn cancel(take self) -> Unit:
        \\        return
        \\
        \\suspend fn await_task(task: Task[I32]) -> I32:
        \\    return task.await :: :: method
        \\
        \\suspend fn cancel_task(task: Task[I32]) -> Unit:
        \\    task.cancel :: :: method
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Task_I32___await(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Task_I32___cancel(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return runa_fn_Task_I32___await(task);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Task_I32___cancel(task);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits exact local struct patterns in subject select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 3, 4 :: call
        \\    select point:
        \\        when Point(x = left, y = right) => return left + right
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "const int32_t left = (runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".x);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "const int32_t right = (runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".y);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local unit enum values and subject select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Color:
        \\    Red
        \\    Blue
        \\
        \\fn main() -> I32:
        \\    let color: Color = Color.Red
        \\    color = Color.Blue
        \\    select color:
        \\        when Color.Red => return 1
        \\        when Color.Blue => return 7
        \\        else => return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef enum runa_tagtype_Color") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_Color") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_tag_Color_Red") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_tag_Color_Blue") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".tag = runa_tag_Color_Blue") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local tuple enum payload construction and subject select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_payload"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Maybe:
        \\    None
        \\    Some(I32)
        \\
        \\fn main() -> I32:
        \\    let value: Maybe = Maybe.Some :: 9 :: call
        \\    select value:
        \\        when Maybe.None => return 0
        \\        when Maybe.Some(found) => return found
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_Maybe") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "union {") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "} Some;") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload = { .Some = { 9 } }") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local named enum payload construction and subject select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_named_payload"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Event:
        \\    Resize:
        \\        width: I32
        \\        height: I32
        \\
        \\fn main() -> I32:
        \\    let event: Event = Event.Resize :: 4, 7 :: call
        \\    select event:
        \\        when Event.Resize(width = w, height = h) => return w + h
        \\    return 0
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_Event") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload = { .Resize = { 4, 7 } }") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload).Resize).width") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload).Resize).height") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 11), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local struct parameter and return types" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn make_point() -> Point:
        \\    return Point :: 5, 2 :: call
        \\
        \\fn sum_point(point: Point) -> I32:
        \\    return point.x + point.y
        \\
        \\fn main() -> I32:
        \\    let point: Point = make_point :: :: call
        \\    return sum_point :: point :: call
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "static runa_type_Point runa_fn_make_point(void);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "static int32_t runa_fn_sum_point(runa_type_Point point);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "point = runa_fn_make_point();") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "return runa_fn_sum_point(point);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits child modules and absolute use imports" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const util_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "util" });
    defer std.testing.allocator.free(util_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, util_dir, .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\mod util
        \\use util.helper as util_helper
        \\use util.VALUE
        \\
        \\fn helper() -> I32:
        \\    return 3
        \\
        \\fn main() -> I32:
        \\    return helper :: :: call + util_helper :: :: call + VALUE
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util/mod.rna",
        .data =
        \\pub(package) const VALUE: I32 = 2
        \\
        \\pub(package) fn helper() -> I32:
        \\    return 4
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_helper(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_util__helper(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_const_util__VALUE") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check accepts grouped use imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const util_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "util" });
    defer std.testing.allocator.free(util_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, util_dir, .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\mod util
        \\use util.{VALUE as ImportedValue, helper as imported_helper}
        \\
        \\fn main() -> I32:
        \\    return imported_helper :: :: call + ImportedValue
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "util/mod.rna",
        .data =
        \\pub(package) const VALUE: I32 = 1
        \\
        \\pub(package) fn helper() -> I32:
        \\    return 2
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expectEqual(@as(usize, 0), pipeline.diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 2), pipeline.sourceFileCount());
}

test "stage0 build resolves path dependency grouped imports" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.{VALUE, helper as dep_helper}
        \\
        \\fn main() -> I32:
        \\    return dep_helper :: :: call + VALUE
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub const VALUE: I32 = 5
        \\
        \\pub fn helper() -> I32:
        \\    return 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__helper(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_const_core__VALUE") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 6), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves imported exact struct patterns in subject select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Point
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 2, 9 :: call
        \\    select point:
        \\        when Point(x = left, y = right) => return right - left
        \\    return 0
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub struct Point:
        \\    pub x: I32
        \\    pub y: I32
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_core__Point") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "const int32_t left = (runa_select_subject_") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "const int32_t right = (runa_select_subject_") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check rejects imported private fields in exact struct patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Point
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 2, 9 :: call
        \\    select point:
        \\        when Point(x = left, y = right) => return right - left
        \\    return 0
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub struct Point:
        \\    x: I32
        \\    y: I32
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    var visibility_errors: usize = 0;
    for (result.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.pattern.field_visibility")) visibility_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), visibility_errors);
}

test "stage0 check rejects missing fields in exact struct patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 1, 2 :: call
        \\    select point:
        \\        when Point(x = left) => return left
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 check rejects duplicate binding names within one exact struct pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 1, 2 :: call
        \\    select point:
        \\        when Point(x = value, y = value) => return value
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 check rejects unknown fields in exact struct patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 1, 2 :: call
        \\    select point:
        \\        when Point(x = left, z = right) => return left
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    try std.testing.expect(pipeline.diagnostics.errorCount() != 0);
}

test "stage0 check rejects unreachable else after irrefutable exact struct pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 1, 2 :: call
        \\    select point:
        \\        when Point(x = left, y = right) => return left + right
        \\        else => return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_unreachable = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.select.unreachable")) {
            saw_unreachable = true;
            break;
        }
    }
    try std.testing.expect(saw_unreachable);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const pattern_result = try compiler.query.patternsByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), pattern_result.summary.checked_subject_pattern_count);
    try std.testing.expectEqual(@as(usize, 1), pattern_result.summary.irrefutable_subject_pattern_count);
    try std.testing.expectEqual(@as(usize, 1), pattern_result.summary.rejected_unreachable_pattern_count);
    const pattern_diagnostic_count = active.pipeline.diagnostics.items.items.len;
    _ = try compiler.query.patternsByBody(&active, main_body_id);
    try std.testing.expectEqual(pattern_diagnostic_count, active.pipeline.diagnostics.items.items.len);
}

test "stage0 check rejects non-exhaustive bool subject selects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn main() -> I32:
        \\    let flag: Bool = true
        \\    select flag:
        \\        when true => return 1
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_non_exhaustive = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.select.non_exhaustive")) {
            saw_non_exhaustive = true;
            break;
        }
    }
    try std.testing.expect(saw_non_exhaustive);

    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const pattern_result = try compiler.query.patternsByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), pattern_result.summary.rejected_non_exhaustive_pattern_count);
}

test "query pattern checks evaluate constant patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\const TARGET: I32 = 2
        \\
        \\fn main() -> I32:
        \\    let code: I32 = 2
        \\    select code:
        \\        when TARGET => return 1
        \\        else => return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    try std.testing.expectEqual(@as(usize, 0), active.pipeline.diagnostics.errorCount());
    const main_item_id = compiler.query.testing.findItemIdByName(&active, "main").?;
    const main_body_id = active.semantic_index.itemEntry(main_item_id).body_id.?;
    const pattern_result = try compiler.query.patternsByBody(&active, main_body_id);
    try std.testing.expectEqual(@as(usize, 1), pattern_result.summary.checked_constant_pattern_count);
    try std.testing.expectEqual(@as(usize, 0), pattern_result.summary.rejected_constant_pattern_count);
}

test "stage0 check uses enum signature facts for subject-select exhaustiveness" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Color:
        \\    Red
        \\    Blue
        \\
        \\fn complete() -> I32:
        \\    let color: Color = Color.Red
        \\    select color:
        \\        when Color.Red => return 1
        \\        when Color.Blue => return 2
        \\    return 0
        \\
        \\fn incomplete() -> I32:
        \\    let color: Color = Color.Red
        \\    select color:
        \\        when Color.Red => return 1
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.session.prepareFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    const complete_item_id = compiler.query.testing.findItemIdByName(&active, "complete").?;
    const complete_body_id = active.semantic_index.itemEntry(complete_item_id).body_id.?;
    const complete_result = try compiler.query.patternsByBody(&active, complete_body_id);
    try std.testing.expectEqual(@as(usize, 0), complete_result.summary.rejected_non_exhaustive_pattern_count);

    const incomplete_item_id = compiler.query.testing.findItemIdByName(&active, "incomplete").?;
    const incomplete_body_id = active.semantic_index.itemEntry(incomplete_item_id).body_id.?;
    const incomplete_result = try compiler.query.patternsByBody(&active, incomplete_body_id);
    try std.testing.expectEqual(@as(usize, 1), incomplete_result.summary.rejected_non_exhaustive_pattern_count);

    var saw_non_exhaustive = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.select.non_exhaustive")) {
            saw_non_exhaustive = true;
            break;
        }
    }
    try std.testing.expect(saw_non_exhaustive);
}

test "stage0 check rejects invalid enum variant pattern shapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\enum Maybe:
        \\    None
        \\    Some(I32)
        \\    Pair:
        \\        left: I32
        \\        right: I32
        \\
        \\fn bad_subject() -> I32:
        \\    let value: I32 = 1
        \\    select value:
        \\        when Maybe.None => return 0
        \\    return 0
        \\
        \\fn bad_enum() -> I32:
        \\    let maybe: Maybe = Maybe.None
        \\    select maybe:
        \\        when Other.None => return 0
        \\    return 0
        \\
        \\fn bad_payload() -> I32:
        \\    let maybe: Maybe = Maybe.Pair :: 1, 2 :: call
        \\    select maybe:
        \\        when Maybe.Pair(left = x) => return x
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();

    var saw_subject = false;
    var saw_missing = false;
    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.pattern.enum_subject")) saw_subject = true;
        if (std.mem.eql(u8, diagnostic.code, "type.pattern.enum_field_missing")) saw_missing = true;
    }

    try std.testing.expect(saw_subject);
    try std.testing.expect(saw_missing);
}

test "stage0 build resolves path dependency nominal function signatures" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.{make_point, sum_point}
        \\
        \\fn main() -> I32:
        \\    let point = make_point :: :: call
        \\    return sum_point :: point :: call
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\pub fn make_point() -> Point:
        \\    return Point :: 2, 5 :: call
        \\
        \\pub fn sum_point(point: Point) -> I32:
        \\    return point.x + point.y
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_core__Point") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "static runa_type_core__Point runa_fn_core__make_point(void);") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "static int32_t runa_fn_core__sum_point(runa_type_core__Point point);") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves imported struct constructor and field projection" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Point
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 3, 4 :: call
        \\    point.x += 1
        \\    return point.x + point.y
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub struct Point:
        \\    x: I32
        \\    y: I32
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_core__Point") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "point = ((runa_type_core__Point){3, 4});") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "point.x += 1;") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 8), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local trait impl take-self methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_trait_method"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Reset:
        \\    fn reset(take self) -> I32
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        \\    fn reset(take self) -> I32:
        \\        return self.value + 1
        \\
        \\fn main() -> I32:
        \\    let counter: Counter = Counter :: 8 :: call
        \\    return counter.reset :: :: method
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Counter__reset(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Counter__reset(counter)") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local trait default take-self methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_trait_default"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Reset:
        \\    fn reset(take self) -> I32:
        \\        return self.value + 2
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        \\
        \\fn main() -> I32:
        \\    let counter: Counter = Counter :: 7 :: call
        \\    return counter.reset :: :: method
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Counter__reset(") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check rejects missing required trait impl methods" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Reset:
        \\    fn reset(take self) -> I32
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_missing = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.method_missing")) {
            found_missing = true;
            break;
        }
    }
    try std.testing.expect(found_missing);
}

test "stage0 check rejects duplicate executable methods on one type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\trait Reset:
        \\    fn reset(take self) -> I32
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Counter:
        \\    fn reset(take self) -> I32:
        \\        return self.value
        \\
        \\impl Reset for Counter:
        \\    fn reset(take self) -> I32:
        \\        return self.value + 1
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_duplicate = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.method.duplicate")) {
            found_duplicate = true;
            break;
        }
    }
    try std.testing.expect(found_duplicate);
}

test "stage0 build resolves imported inherent methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Point
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 3, 4 :: call
        \\    return point.total :: 5 :: method
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\impl Point:
        \\    fn total(take self, extra: I32) -> I32:
        \\        return self.x + self.y + extra
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__Point__total(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__Point__total(point, 5)") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 12), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves imported trait impl methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_trait_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Counter
        \\
        \\fn main() -> I32:
        \\    let counter: Counter = Counter :: 6 :: call
        \\    return counter.reset :: :: method
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub trait Reset:
        \\    fn reset(take self) -> I32
        \\
        \\pub struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        \\    fn reset(take self) -> I32:
        \\        return self.value + 3
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__Counter__reset(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__Counter__reset(counter)") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves imported trait default methods for local impls" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_trait_default_import"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Reset
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        \\
        \\fn main() -> I32:
        \\    let counter: Counter = Counter :: 5 :: call
        \\    return counter.reset :: :: method
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub trait Reset:
        \\    fn reset(take self) -> I32:
        \\        return self.value + 4
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 9), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local read and edit parameter functions" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_borrow_params"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\fn sum(read point: Point) -> I32:
        \\    return point.x + point.y
        \\
        \\fn bump(edit point: Point) -> Unit:
        \\    point.x += 1
        \\    point.y = point.y + 2
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 3, 4 :: call
        \\    bump :: point :: call
        \\    return sum :: point :: call
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_bump(&point)") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_sum(&point)") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "(*point).x") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 10), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build emits local edit self methods" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_edit_method"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Counter:
        \\    fn bump(edit self) -> I32:
        \\        self.value += 1
        \\        return self.value
        \\
        \\fn main() -> I32:
        \\    let counter: Counter = Counter :: 8 :: call
        \\    let current: I32 = counter.bump :: :: method
        \\    return counter.value + current
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_Counter__bump(&counter)") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "(*self).value") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 18), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check rejects assignment to read parameters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn bad(read value: I32) -> I32:
        \\    value = value + 1
        \\    return value
        \\
        \\fn main() -> I32:
        \\    return 0
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_immutable = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.assign.immutable")) {
            found_immutable = true;
            break;
        }
    }
    try std.testing.expect(found_immutable);
}

test "stage0 check rejects non-place read borrow call arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\fn inspect(read value: I32) -> I32:
        \\    return value
        \\
        \\fn main() -> I32:
        \\    return inspect :: 1 :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_borrow_arg = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.call.borrow_arg")) {
            found_borrow_arg = true;
            break;
        }
    }
    try std.testing.expect(found_borrow_arg);
}

test "stage0 build resolves imported read and edit parameter functions" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_import_borrow"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Point
        \\use core.bump
        \\use core.sum
        \\
        \\fn main() -> I32:
        \\    let point: Point = Point :: 1, 2 :: call
        \\    bump :: point :: call
        \\    return sum :: point :: call
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub struct Point:
        \\    x: I32
        \\    y: I32
        \\
        \\pub fn sum(read point: Point) -> I32:
        \\    return point.x + point.y
        \\
        \\pub fn bump(edit point: Point) -> Unit:
        \\    point.x += 2
        \\    point.y += 3
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__bump(&point)") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__sum(&point)") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 8), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build rejects immutable locals for imported edit borrows" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.touch
        \\
        \\fn main() -> I32:
        \\    const value: I32 = 1
        \\    touch :: value :: call
        \\    return 0
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub fn touch(edit value: I32) -> Unit:
        \\    value = value + 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    var found_borrow_mut = false;
    for (result.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.call.borrow_mut")) {
            found_borrow_mut = true;
            break;
        }
    }
    try std.testing.expect(found_borrow_mut);
}

test "stage0 check rejects missing required imported trait methods" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Reset
        \\
        \\struct Counter:
        \\    value: I32
        \\
        \\impl Reset for Counter:
        \\    
        \\fn main() -> I32:
        \\    return 0
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub trait Reset:
        \\    fn reset(take self) -> I32
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    var found_missing = false;
    for (result.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.impl.method_missing")) {
            found_missing = true;
            break;
        }
    }
    try std.testing.expect(found_missing);
}

test "stage0 build resolves imported unit enum values and select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Color
        \\
        \\fn main() -> I32:
        \\    let color: Color = Color.Blue
        \\    select color:
        \\        when Color.Red => return 1
        \\        when Color.Blue => return 7
        \\        else => return 0
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\pub enum Color:
        \\    Red
        \\    Blue
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef enum runa_tagtype_core__Color") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_core__Color") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".tag = runa_tag_core__Color_Blue") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves imported tuple enum payload construction and select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "0.1.0" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Maybe
        \\
        \\fn main() -> I32:
        \\    let value: Maybe = Maybe.Some :: 11 :: call
        \\    select value:
        \\        when Maybe.None => return 0
        \\        when Maybe.Some(found) => return found
        \\    return 0
        ,
    });

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    const core_manifest = try std.fs.path.join(std.testing.allocator, &.{ core_dir, "runa.toml" });
    defer std.testing.allocator.free(core_manifest);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = core_manifest,
        .data =
        \\[package]
        \\name = "core"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });

    const core_source = try std.fs.path.join(std.testing.allocator, &.{ core_dir, "lib.rna" });
    defer std.testing.allocator.free(core_source);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = core_source,
        .data =
        \\pub enum Maybe:
        \\    None
        \\    Some(I32)
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_core__Maybe") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload = { .Some = { 11 } }") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 11), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves imported named enum payload construction and select" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "deps/core", version = "0.1.0" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.Event
        \\
        \\fn main() -> I32:
        \\    let event: Event = Event.Resize :: 3, 5 :: call
        \\    select event:
        \\        when Event.Resize(width = w, height = h) => return w * h
        \\    return 0
        ,
    });

    const deps_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(deps_dir);
    std.Io.Dir.cwd().createDir(std.testing.io, deps_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ deps_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const core_manifest = try std.fs.path.join(std.testing.allocator, &.{ core_dir, "runa.toml" });
    defer std.testing.allocator.free(core_manifest);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = core_manifest,
        .data =
        \\[package]
        \\name = "core"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });

    const core_source = try std.fs.path.join(std.testing.allocator, &.{ core_dir, "lib.rna" });
    defer std.testing.allocator.free(core_source);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = core_source,
        .data =
        \\pub enum Event:
        \\    Resize:
        \\        pub width: I32
        \\        pub height: I32
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "typedef struct runa_type_core__Event") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload = { .Resize = { 3, 5 } }") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload).Resize).width") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, ".payload).Resize).height") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 15), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build resolves published registry dependency imports" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    const pkg_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "packages" });
    defer std.testing.allocator.free(pkg_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, pkg_dir, .default_dir);

    const core_dir = try std.fs.path.join(std.testing.allocator, &.{ pkg_dir, "core" });
    defer std.testing.allocator.free(core_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, core_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packages/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packages/core/lib.rna",
        .data =
        \\pub const VALUE: I32 = 8
        \\
        \\pub fn helper() -> I32:
        \\    return 3
        ,
    });

    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "managed-store" });
    defer std.testing.allocator.free(store_root);

    var published = try toolchain.publish.publishAtPath(std.testing.allocator, std.testing.io, core_dir, "primary", store_root);
    defer published.deinit(std.testing.allocator);

    const app_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "app" });
    defer std.testing.allocator.free(app_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, app_dir, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app/runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { version = "1.2.3", registry = "primary" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app/main.rna",
        .data =
        \\use core.{VALUE, helper as dep_helper}
        \\
        \\fn main() -> I32:
        \\    return dep_helper :: :: call + VALUE
        ,
    });

    var result = try toolchain.build.buildAtPathWithOptions(std.testing.allocator, std.testing.io, app_dir, .{
        .store_root_override = store_root,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        const c_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, artifact.c_path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(c_source);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_fn_core__helper(") != null);
        try std.testing.expect(std.mem.indexOf(u8, c_source, "runa_const_core__VALUE") != null);

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 11), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 check rejects unsafe local calls outside unsafe context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#unsafe
        \\fn touch(value: I32) -> I32:
        \\    return value + 1
        \\
        \\fn main() -> I32:
        \\    return touch :: 4 :: call
        ,
    });

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ root, "main.rna" });
    defer std.testing.allocator.free(main_path);

    var active = try compiler.semantic.openFiles(std.testing.allocator, std.testing.io, &.{main_path});
    defer active.deinit();
    const pipeline = &active.pipeline;

    var found_unsafe = false;
    for (pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.call.unsafe")) {
            found_unsafe = true;
            break;
        }
    }
    try std.testing.expect(found_unsafe);
}

test "stage0 build accepts unsafe expr and unsafe block contexts" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\#unsafe
        \\fn touch(value: I32) -> I32:
        \\    return value + 1
        \\
        \\fn main() -> I32:
        \\    let first: I32 = #unsafe touch :: 4 :: call
        \\    #unsafe:
        \\        let second: I32 = touch :: first :: call
        \\        return second
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.pipeline.diagnostics.errorCount());

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;

        const run_result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer std.testing.allocator.free(run_result.stdout);
        defer std.testing.allocator.free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 6), code),
            else => return error.UnexpectedTestResult,
        }
    }
}

test "stage0 build rejects imported unsafe calls outside unsafe context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const dep_root = try std.fs.path.join(std.testing.allocator, &.{ root, "deps" });
    defer std.testing.allocator.free(dep_root);
    const dep_core = try std.fs.path.join(std.testing.allocator, &.{ root, "deps", "core" });
    defer std.testing.allocator.free(dep_core);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep_root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, dep_core, .default_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runa.toml",
        .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[dependencies]
        \\core = { path = "./deps/core", version = "1.2.3" }
        \\
        \\[[products]]
        \\kind = "bin"
        \\name = "demo_app"
        \\root = "main.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.rna",
        .data =
        \\use core.touch
        \\
        \\fn main() -> I32:
        \\    return touch :: 4 :: call
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/runa.toml",
        .data =
        \\[package]
        \\name = "core"
        \\version = "1.2.3"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "lib"
        \\root = "lib.rna"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deps/core/lib.rna",
        .data =
        \\#unsafe
        \\pub fn touch(value: I32) -> I32:
        \\    return value + 1
        ,
    });

    var result = try toolchain.build.buildAtPath(std.testing.allocator, std.testing.io, root);
    defer result.deinit();

    var found_unsafe = false;
    for (result.pipeline.diagnostics.items.items) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "type.call.unsafe")) {
            found_unsafe = true;
            break;
        }
    }
    try std.testing.expect(found_unsafe);
}

fn collectRootPaths(allocator: std.mem.Allocator, products: []const toolchain.workspace.ResolvedProduct) ![][]const u8 {
    var paths = try allocator.alloc([]const u8, products.len);
    for (products, 0..) |product, index| paths[index] = product.root_path;
    return paths;
}
