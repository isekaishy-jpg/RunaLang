const std = @import("std");
const compiler = @import("compiler");
const cli_context = @import("../cli/context.zig");
const workspace = @import("../workspace/root.zig");

const Allocator = std.mem.Allocator;

pub const summary = "Query-backed #test discovery and execution boundary.";
pub const discovery_attribute = "#test";
pub const product_name_heuristics_are_removed = true;

pub const TestDescriptor = compiler.query.TestDescriptor;
pub const PackageTestResult = compiler.query.PackageTestResult;

pub const Options = struct {
    parallel: bool = false,
    no_capture: bool = false,
};

pub const Summary = struct {
    discovered: usize = 0,
    executed: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    harness_failures: usize = 0,
};

pub const TestProgress = struct {
    package_name: []const u8,
    function_name: []const u8,
    passed: bool,
};

pub const PackageRunSummary = struct {
    package_name: []const u8,
    discovered: usize = 0,
    executed: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    harness_failures: usize = 0,
};

pub const CommandResult = struct {
    allocator: Allocator,
    prep: workspace.CompilerPrep,
    active: compiler.session.Session,
    packages: []PackageTestResult,
    progress: std.array_list.Managed(TestProgress),
    package_summaries: std.array_list.Managed(PackageRunSummary),
    summary: Summary,

    pub fn deinit(self: *CommandResult) void {
        self.package_summaries.deinit();
        self.progress.deinit();
        for (self.packages) |package_result| package_result.deinit(self.allocator);
        if (self.packages.len != 0) self.allocator.free(self.packages);
        self.active.deinit();
        self.prep.deinit();
    }

    pub fn failed(self: *const CommandResult) bool {
        return self.active.pipeline.diagnostics.hasErrors() or
            self.summary.failed != 0 or
            self.summary.harness_failures != 0;
    }
};

pub fn runCommandContext(
    allocator: Allocator,
    io: std.Io,
    command_context: *const cli_context.CommandContext,
    options: Options,
) !CommandResult {
    return switch (command_context.*) {
        .manifest_rooted => |*manifest_rooted| runManifestRooted(allocator, io, manifest_rooted, options),
        .standalone => error.MissingManifest,
    };
}

pub fn runManifestRooted(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: Options,
) !CommandResult {
    var prep = try manifest_rooted.prepareCompilerInputs(io, .local_authoring);
    errdefer prep.deinit();

    var active = try compiler.semantic.openGraph(allocator, io, prep.compiler_graph.graph);
    errdefer active.deinit();

    const packages = if (active.pipeline.diagnostics.hasErrors())
        try allocator.alloc(PackageTestResult, 0)
    else
        try discoverScopedPackageTests(allocator, manifest_rooted, &prep.graph, &active);
    errdefer {
        for (packages) |package_result| package_result.deinit(allocator);
        if (packages.len != 0) allocator.free(packages);
    }

    var result = CommandResult{
        .allocator = allocator,
        .prep = prep,
        .active = active,
        .packages = packages,
        .progress = std.array_list.Managed(TestProgress).init(allocator),
        .package_summaries = std.array_list.Managed(PackageRunSummary).init(allocator),
        .summary = .{},
    };
    errdefer result.deinit();

    for (result.packages) |package_result| result.summary.discovered += package_result.tests.len;
    if (result.active.pipeline.diagnostics.hasErrors()) return result;

    if (!compiler.target.hostStage0Supported()) {
        try result.active.pipeline.diagnostics.add(
            .@"error",
            "test.target.unsupported",
            null,
            "stage0 test execution is only implemented for supported Windows hosts; current host is '{s}'",
            .{compiler.target.hostName()},
        );
        result.summary.harness_failures += @intFromBool(result.summary.discovered != 0);
        return result;
    }

    if (options.parallel) {
        try runPackageHarnessesParallel(allocator, io, manifest_rooted.command_root, &result, options);
    } else {
        for (result.packages) |package_result| {
            if (package_result.tests.len == 0) continue;
            try runPackageHarness(allocator, io, manifest_rooted.command_root, &result, package_result, options);
            if (result.summary.failed != 0 or result.summary.harness_failures != 0) break;
        }
    }

    return result;
}

fn discoverScopedPackageTests(
    allocator: Allocator,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    graph: *const workspace.Graph,
    active: *compiler.session.Session,
) ![]PackageTestResult {
    var results = std.array_list.Managed(PackageTestResult).init(allocator);
    errdefer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit();
    }

    for (graph.packages.items, 0..) |_, package_index| {
        if (!packageInLocalAuthoringScope(manifest_rooted, graph, package_index)) continue;
        try results.append(try compiler.query.discoverPackageTests(allocator, active, package_index));
    }

    return results.toOwnedSlice();
}

fn packageInLocalAuthoringScope(
    manifest_rooted: *const cli_context.ManifestRootedContext,
    graph: *const workspace.Graph,
    package_index: usize,
) bool {
    for (graph.root_products.items) |product| {
        const root_package_index = product.package_index orelse graph.root_package_index;
        if (root_package_index == package_index) return true;
    }

    const package_node = graph.packages.items[package_index];
    return workspace.packageOriginWithStore(manifest_rooted.command_root, manifest_rooted.storeRootOverride(), package_node.root_dir) == .vendored;
}

fn runPackageHarness(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    result: *CommandResult,
    package_result: PackageTestResult,
    options: Options,
) !void {
    if (packageUsesSingleTestHarnesses(&result.active, package_result, options)) {
        try runPackageSingleTestHarnesses(allocator, io, command_root, result, package_result, options);
        return;
    }

    const package_node = result.prep.graph.packages.items[package_result.package_index];
    var harness = buildPackageHarness(
        allocator,
        io,
        command_root,
        &package_node,
        &result.active,
        package_result,
        &result.active.pipeline.diagnostics,
        "__runa_package_harness",
        !options.no_capture,
    ) catch |err| {
        try appendPackageHarnessFailure(result, package_result, "test.harness.build", "test harness build failed for package '{s}': {s}", err);
        return;
    };
    defer harness.deinit(allocator, io);

    var run_result = runHarnessProcess(allocator, io, harness.artifact.path, package_node.root_dir, options.no_capture) catch |err| {
        try appendPackageHarnessFailure(result, package_result, "test.harness.launch", "test harness launch failed for package '{s}': {s}", err);
        return;
    };
    defer run_result.deinit();
    try accountPackageHarnessRun(result, package_result, &run_result);
}

fn packageUsesSingleTestHarnesses(
    active: *const compiler.session.Session,
    package_result: PackageTestResult,
    options: Options,
) bool {
    if (options.parallel and package_result.tests.len > 1) return true;
    if (options.no_capture) return package_result.tests.len > 1;
    return !packageCanEmitStatusMarkers(active, package_result);
}

fn packageCanEmitStatusMarkers(
    active: *const compiler.session.Session,
    package_result: PackageTestResult,
) bool {
    for (package_result.tests) |descriptor| {
        if (moduleDeclaresName(active, descriptor.root_module_relative_path, "putchar")) return false;
    }
    return true;
}

fn runPackageSingleTestHarnesses(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    result: *CommandResult,
    package_result: PackageTestResult,
    options: Options,
) !void {
    const package_node = result.prep.graph.packages.items[package_result.package_index];
    var package_summary = PackageRunSummary{
        .package_name = package_result.package_name,
        .discovered = package_result.tests.len,
    };
    var entries = std.array_list.Managed(BuiltSingleTestHarnessEntry).init(allocator);
    defer {
        for (entries.items) |*entry| entry.deinit(allocator, io);
        entries.deinit();
    }

    for (package_result.tests, 0..) |descriptor, test_index| {
        const single_test = try singleTestPackageResult(allocator, package_result, test_index);
        defer freeSingleTestPackageResult(allocator, single_test);
        const harness_stem = try std.fmt.allocPrint(allocator, "__runa_test_{d}", .{test_index});
        defer allocator.free(harness_stem);

        var harness = buildPackageHarness(
            allocator,
            io,
            command_root,
            &package_node,
            &result.active,
            single_test,
            &result.active.pipeline.diagnostics,
            harness_stem,
            false,
        ) catch |err| {
            try appendSingleTestHarnessFailure(result, package_result, descriptor, "test.harness.build", "build", err);
            package_summary.harness_failures += 1;
            try appendSingleTestPackageSummary(result, package_summary);
            return;
        };
        var keep_harness = false;
        errdefer if (!keep_harness) harness.deinit(allocator, io);
        try entries.append(.{
            .descriptor = descriptor,
            .harness = harness,
        });
        keep_harness = true;
    }

    if (options.parallel and entries.items.len > 1) {
        try runSingleTestHarnessEntriesParallel(allocator, io, result, package_result, package_node.root_dir, entries.items, options, &package_summary);
    } else {
        try runSingleTestHarnessEntriesSerial(allocator, io, result, package_result, package_node.root_dir, entries.items, options, &package_summary);
    }

    try appendSingleTestPackageSummary(result, package_summary);
}

fn appendSingleTestPackageSummary(
    result: *CommandResult,
    package_summary: PackageRunSummary,
) !void {
    result.summary.executed += package_summary.executed;
    result.summary.passed += package_summary.passed;
    result.summary.failed += package_summary.failed;
    result.summary.harness_failures += package_summary.harness_failures;
    try result.package_summaries.append(package_summary);
}

const BuiltSingleTestHarnessEntry = struct {
    descriptor: TestDescriptor,
    harness: BuiltPackageHarness,

    fn deinit(self: *BuiltSingleTestHarnessEntry, allocator: Allocator, io: std.Io) void {
        self.harness.deinit(allocator, io);
    }
};

fn runSingleTestHarnessEntriesSerial(
    allocator: Allocator,
    io: std.Io,
    result: *CommandResult,
    package_result: PackageTestResult,
    package_root: []const u8,
    entries: []BuiltSingleTestHarnessEntry,
    options: Options,
    package_summary: *PackageRunSummary,
) !void {
    for (entries) |*entry| {
        var run_result = runHarnessProcess(allocator, io, entry.harness.artifact.path, package_root, options.no_capture) catch |err| {
            try appendSingleTestHarnessFailure(result, package_result, entry.descriptor, "test.harness.launch", "launch", err);
            package_summary.harness_failures += 1;
            break;
        };
        defer run_result.deinit();

        const harness_failed = try accountSingleTestHarnessRun(result, package_result, entry.descriptor, &run_result, package_summary);
        if (harness_failed) break;
    }
}

fn runSingleTestHarnessEntriesParallel(
    allocator: Allocator,
    io: std.Io,
    result: *CommandResult,
    package_result: PackageTestResult,
    package_root: []const u8,
    entries: []BuiltSingleTestHarnessEntry,
    options: Options,
    package_summary: *PackageRunSummary,
) !void {
    var workers = try allocator.alloc(ParallelPackageHarnessWorker, entries.len);
    for (workers) |*worker| {
        worker.* = .{
            .io = io,
            .package_root = "",
            .harness_path = "",
            .no_capture = false,
        };
    }
    defer {
        for (workers) |*worker| worker.deinit();
        allocator.free(workers);
    }

    var started: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < started) : (index += 1) workers[index].join();
    }

    for (entries, 0..) |entry, index| {
        workers[index] = .{
            .io = io,
            .package_root = package_root,
            .harness_path = entry.harness.artifact.path,
            .no_capture = options.no_capture,
        };
        try workers[index].start();
        started += 1;
    }

    for (workers) |*worker| worker.join();

    for (entries, 0..) |entry, index| {
        const worker = &workers[index];
        if (worker.launch_error) |err| {
            try appendSingleTestHarnessFailure(result, package_result, entry.descriptor, "test.harness.launch", "launch", err);
            package_summary.harness_failures += 1;
            continue;
        }
        if (worker.result) |*run_result| {
            _ = try accountSingleTestHarnessRun(result, package_result, entry.descriptor, run_result, package_summary);
        }
    }
}

fn appendSingleTestHarnessFailure(
    result: *CommandResult,
    package_result: PackageTestResult,
    descriptor: TestDescriptor,
    code: []const u8,
    action: []const u8,
    err: anyerror,
) !void {
    try result.active.pipeline.diagnostics.add(
        .@"error",
        code,
        null,
        "test harness {s} failed for package '{s}' test '{s}': {s}",
        .{ action, package_result.package_name, descriptor.function_name, @errorName(err) },
    );
}

fn singleTestPackageResult(
    allocator: Allocator,
    package_result: PackageTestResult,
    test_index: usize,
) !PackageTestResult {
    const tests = try allocator.alloc(TestDescriptor, 1);
    tests[0] = package_result.tests[test_index];
    return .{
        .package_index = package_result.package_index,
        .package_name = package_result.package_name,
        .tests = tests,
    };
}

fn freeSingleTestPackageResult(allocator: Allocator, package_result: PackageTestResult) void {
    if (package_result.tests.len != 0) allocator.free(package_result.tests);
}

fn accountSingleTestHarnessRun(
    result: *CommandResult,
    package_result: PackageTestResult,
    descriptor: TestDescriptor,
    run_result: *const HarnessRunResult,
    package_summary: *PackageRunSummary,
) !bool {
    switch (run_result.term) {
        .exited => |code| {
            const failed = code != 0;
            package_summary.executed += 1;
            if (failed) {
                package_summary.failed += 1;
                try appendCapturedOutputDiagnostics(
                    &result.active.pipeline.diagnostics,
                    package_result.package_name,
                    descriptor.function_name,
                    run_result.stdout,
                    run_result.stderr,
                );
            } else {
                package_summary.passed += 1;
            }
            try result.progress.append(.{
                .package_name = package_result.package_name,
                .function_name = descriptor.function_name,
                .passed = !failed,
            });
            return false;
        },
        else => {
            package_summary.harness_failures += 1;
            try appendCapturedOutputDiagnostics(
                &result.active.pipeline.diagnostics,
                package_result.package_name,
                descriptor.function_name,
                run_result.stdout,
                run_result.stderr,
            );
            return true;
        },
    }
}

fn appendPackageHarnessFailure(
    result: *CommandResult,
    package_result: PackageTestResult,
    code: []const u8,
    comptime message: []const u8,
    err: anyerror,
) !void {
    try result.active.pipeline.diagnostics.add(.@"error", code, null, message, .{ package_result.package_name, @errorName(err) });
    result.summary.harness_failures += 1;
    try result.package_summaries.append(.{
        .package_name = package_result.package_name,
        .discovered = package_result.tests.len,
        .harness_failures = 1,
    });
}

const ParallelPackageHarnessWorker = struct {
    io: std.Io,
    package_root: []const u8,
    harness_path: []const u8,
    no_capture: bool,
    result: ?HarnessRunResult = null,
    launch_error: ?anyerror = null,
    thread: ?std.Thread = null,

    fn start(self: *ParallelPackageHarnessWorker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn join(self: *ParallelPackageHarnessWorker) void {
        if (self.thread) |thread| thread.join();
    }

    fn deinit(self: *ParallelPackageHarnessWorker) void {
        if (self.result) |run_result| run_result.deinit();
    }

    fn run(self: *ParallelPackageHarnessWorker) void {
        self.result = runHarnessProcess(
            std.heap.page_allocator,
            self.io,
            self.harness_path,
            self.package_root,
            self.no_capture,
        ) catch |err| {
            self.launch_error = err;
            return;
        };
    }
};

fn runPackageHarnessesParallel(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    result: *CommandResult,
    options: Options,
) !void {
    for (result.packages) |package_result| {
        if (package_result.tests.len == 0) continue;
        try runPackageHarness(allocator, io, command_root, result, package_result, options);
        if (result.summary.failed != 0 or result.summary.harness_failures != 0) break;
    }
}

const HarnessRunResult = struct {
    term: std.process.Child.Term,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    output_allocator: Allocator,

    fn deinit(self: HarnessRunResult) void {
        if (self.stdout) |bytes| self.output_allocator.free(bytes);
        if (self.stderr) |bytes| self.output_allocator.free(bytes);
    }
};

const BuiltPackageHarness = struct {
    scratch_root: []const u8,
    artifact: HarnessArtifact,

    fn deinit(self: *BuiltPackageHarness, allocator: Allocator, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.scratch_root) catch {};
        allocator.free(self.scratch_root);
        self.artifact.deinit(allocator);
    }
};

fn buildPackageHarness(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    package_node: *const workspace.PackageNode,
    active: *compiler.session.Session,
    package_result: PackageTestResult,
    diagnostics: *compiler.diag.Bag,
    harness_stem: []const u8,
    emit_status_markers: bool,
) !BuiltPackageHarness {
    if (package_result.tests.len == 0) return error.EmptyTestPackage;
    const root_path = rootModulePathForTest(active, package_result.tests[0]) orelse package_result.tests[0].root_module_relative_path;
    const root_relative = relativePathText(package_node.root_dir, root_path) orelse return error.InvalidTestRootPath;

    const scratch_root = try std.fs.path.join(allocator, &.{
        command_root,
        "target",
        compiler.target.hostName(),
        "debug",
        package_node.package_name,
        "__test",
        harness_stem,
        "src",
    });
    errdefer allocator.free(scratch_root);
    try std.Io.Dir.cwd().deleteTree(io, scratch_root);
    try ensureDirPath(io, scratch_root);

    try copyHarnessSourceTree(allocator, io, package_node.root_dir, scratch_root, root_path, active, package_result, emit_status_markers);

    const harness_path = try std.fs.path.join(allocator, &.{ scratch_root, root_relative });
    defer allocator.free(harness_path);

    const artifact = try buildHarnessExecutable(allocator, io, command_root, package_node.package_name, harness_stem, harness_path, diagnostics);
    return .{
        .scratch_root = scratch_root,
        .artifact = artifact,
    };
}

fn copyHarnessSourceTree(
    allocator: Allocator,
    io: std.Io,
    package_root: []const u8,
    scratch_root: []const u8,
    harness_root_path: []const u8,
    active: *compiler.session.Session,
    package_result: PackageTestResult,
    emit_status_markers: bool,
) !void {
    var dir = try openIterableDir(io, package_root);
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isExcludedPackageDir(entry.path)) walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".rna")) continue;

        const source_path = try std.fs.path.join(allocator, &.{ package_root, entry.path });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &.{ scratch_root, entry.path });
        defer allocator.free(dest_path);
        try ensureParentDir(io, dest_path);

        const contents = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(contents);
        const rendered = try renderHarnessModuleSource(allocator, contents, source_path, harness_root_path, active, package_result, emit_status_markers);
        defer allocator.free(rendered);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = rendered });
    }
}

fn renderHarnessModuleSource(
    allocator: Allocator,
    source_contents: []const u8,
    source_path: []const u8,
    harness_root_path: []const u8,
    active: *compiler.session.Session,
    package_result: PackageTestResult,
    emit_status_markers: bool,
) ![]const u8 {
    const is_root = std.mem.eql(u8, source_path, harness_root_path);
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    if (is_root) {
        try appendSourceWithoutUserMain(&out, source_contents, active, source_path);
    } else {
        try out.appendSlice(source_contents);
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') try out.append('\n');

    if (is_root) {
        try appendHarnessImports(allocator, &out, package_result);
    }
    const can_emit_status_markers = emit_status_markers and
        moduleHasTestWrappers(package_result, source_path) and
        !moduleDeclaresName(active, source_path, "putchar");
    if (can_emit_status_markers) {
        try appendHarnessStatusExtern(&out);
    }
    for (package_result.tests, 0..) |descriptor, index| {
        if (!std.mem.eql(u8, descriptor.root_module_relative_path, source_path)) continue;
        try appendHarnessWrapper(allocator, &out, active, descriptor, index, !is_root, can_emit_status_markers);
    }
    if (is_root) try appendHarnessMain(allocator, &out, package_result);
    return out.toOwnedSlice();
}

fn runHarnessProcess(
    allocator: Allocator,
    io: std.Io,
    harness_path: []const u8,
    package_root: []const u8,
    no_capture: bool,
) !HarnessRunResult {
    if (!no_capture) {
        const captured = try std.process.run(allocator, io, .{
            .argv = &.{harness_path},
            .cwd = .{ .path = package_root },
        });
        return .{
            .term = captured.term,
            .stdout = captured.stdout,
            .stderr = captured.stderr,
            .output_allocator = allocator,
        };
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{harness_path},
        .cwd = .{ .path = package_root },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(io);
    return .{
        .term = try child.wait(io),
        .output_allocator = allocator,
    };
}

fn appendCapturedOutputDiagnostics(
    diagnostics: *compiler.diag.Bag,
    package_name: []const u8,
    function_name: []const u8,
    stdout: ?[]const u8,
    stderr: ?[]const u8,
) !void {
    if (stdout) |bytes| {
        if (bytes.len != 0) {
            try diagnostics.add(.warning, "test.output.stdout", null, "captured stdout for package '{s}' test '{s}':\n{s}", .{ package_name, function_name, bytes });
        }
    }
    if (stderr) |bytes| {
        if (bytes.len != 0) {
            try diagnostics.add(.warning, "test.output.stderr", null, "captured stderr for package '{s}' test '{s}':\n{s}", .{ package_name, function_name, bytes });
        }
    }
}

fn accountPackageHarnessRun(
    result: *CommandResult,
    package_result: PackageTestResult,
    run_result: *const HarnessRunResult,
) !void {
    var package_summary = PackageRunSummary{
        .package_name = package_result.package_name,
        .discovered = package_result.tests.len,
    };
    switch (run_result.term) {
        .exited => |code| {
            var parsed_status = try parseHarnessStatusOutput(result.allocator, package_result, run_result.stdout);
            defer parsed_status.deinit(result.allocator);
            const failed_count: usize = @intCast(code);
            package_summary.executed = package_result.tests.len;
            for (package_result.tests, 0..) |descriptor, index| {
                const failed = if (index < parsed_status.statuses.len)
                    parsed_status.statuses[index] orelse (index < failed_count)
                else
                    index < failed_count;
                if (failed) {
                    package_summary.failed += 1;
                } else {
                    package_summary.passed += 1;
                }
                try result.progress.append(.{
                    .package_name = package_result.package_name,
                    .function_name = descriptor.function_name,
                    .passed = !failed,
                });
            }
            if (package_summary.failed != 0) {
                try appendCapturedOutputDiagnostics(
                    &result.active.pipeline.diagnostics,
                    package_result.package_name,
                    "package",
                    parsed_status.cleaned_stdout orelse run_result.stdout,
                    run_result.stderr,
                );
            }
        },
        else => {
            package_summary.harness_failures = 1;
            try appendCapturedOutputDiagnostics(&result.active.pipeline.diagnostics, package_result.package_name, "package", run_result.stdout, run_result.stderr);
        },
    }

    result.summary.executed += package_summary.executed;
    result.summary.passed += package_summary.passed;
    result.summary.failed += package_summary.failed;
    result.summary.harness_failures += package_summary.harness_failures;
    try result.package_summaries.append(package_summary);
}

fn appendHarnessImports(
    allocator: Allocator,
    out: *std.array_list.Managed(u8),
    package_result: PackageTestResult,
) !void {
    for (package_result.tests, 0..) |descriptor, index| {
        if (descriptor.module_path.len == 0) continue;
        try appendFmt(allocator, out, "use {s}.__runa_test_{d} as __runa_test_{d}\n", .{ descriptor.module_path, index, index });
    }
    if (package_result.tests.len != 0) try out.append('\n');
}

fn moduleHasTestWrappers(package_result: PackageTestResult, source_path: []const u8) bool {
    for (package_result.tests) |descriptor| {
        if (std.mem.eql(u8, descriptor.root_module_relative_path, source_path)) return true;
    }
    return false;
}

fn appendHarnessStatusExtern(out: *std.array_list.Managed(u8)) !void {
    try out.appendSlice(
        \\#link[name = "msvcrt"]
        \\#unsafe
        \\extern["c"] fn putchar(value: CInt) -> CInt
        \\
        \\
    );
}

fn appendHarnessWrapper(
    allocator: Allocator,
    out: *std.array_list.Managed(u8),
    active: *compiler.session.Session,
    descriptor: TestDescriptor,
    index: usize,
    public: bool,
    emit_status_marker: bool,
) !void {
    const checked = try compiler.query.checkedSignature(active, descriptor.item_id);
    const function = switch (checked.facts) {
        .function => |function| function,
        else => return error.InvalidTestDescriptor,
    };
    if (public) try out.appendSlice("pub ");
    try appendFmt(allocator, out, "fn __runa_test_{d}() -> I32:\n", .{index});
    if (function.return_type.eql(compiler.types.TypeRef.fromBuiltin(.unit))) {
        try appendFmt(allocator, out, "    {s} :: :: call\n", .{descriptor.function_name});
        if (emit_status_marker) try appendHarnessStatusCall(allocator, out, index, true);
        try out.appendSlice("    return 0\n");
    } else if (try compiler.query.standard_families.resultTypeArgsMatch(
        allocator,
        function.return_type,
        compiler.types.TypeRef.fromBuiltin(.unit),
        compiler.types.TypeRef.fromBuiltin(.str),
    )) {
        try appendFmt(allocator, out, "    let runa_test_result: Result[Unit, Str] = {s} :: :: call\n", .{descriptor.function_name});
        try out.appendSlice("    let runa_test_failed: Bool = runa_test_result.is_err :: :: method\n");
        try out.appendSlice("    select runa_test_failed:\n");
        try out.appendSlice("        when true =>\n");
        if (emit_status_marker) try appendHarnessStatusCallIndented(allocator, out, index, false, 12);
        try out.appendSlice("            return 1\n");
        try out.appendSlice("        when false =>\n");
        if (emit_status_marker) try appendHarnessStatusCallIndented(allocator, out, index, true, 12);
        try out.appendSlice("            runa_test_failed = false\n");
        try out.appendSlice("    return 0\n");
    } else {
        return error.InvalidTestDescriptor;
    }
    try out.append('\n');
}

fn appendHarnessStatusCall(
    allocator: Allocator,
    out: *std.array_list.Managed(u8),
    index: usize,
    passed: bool,
) !void {
    try appendHarnessStatusCallIndented(allocator, out, index, passed, 4);
}

fn appendHarnessStatusCallIndented(
    allocator: Allocator,
    out: *std.array_list.Managed(u8),
    index: usize,
    passed: bool,
    indent: usize,
) !void {
    const marker = try statusMarker(allocator, index, passed);
    defer allocator.free(marker);
    for (marker, 0..) |byte, byte_index| {
        try out.appendNTimes(' ', indent);
        try appendFmt(
            allocator,
            out,
            "let __runa_test_status_{s}_{d}_{d}_value: CInt = {d}\n",
            .{ if (passed) "pass" else "fail", index, byte_index, byte },
        );
        try out.appendNTimes(' ', indent);
        try appendFmt(
            allocator,
            out,
            "let __runa_test_status_{s}_{d}_{d}: CInt = #unsafe putchar :: __runa_test_status_{s}_{d}_{d}_value :: call\n",
            .{ if (passed) "pass" else "fail", index, byte_index, if (passed) "pass" else "fail", index, byte_index },
        );
    }
    try out.appendNTimes(' ', indent);
    try appendFmt(
        allocator,
        out,
        "let __runa_test_status_{s}_{d}_newline_value: CInt = 10\n",
        .{ if (passed) "pass" else "fail", index },
    );
    try out.appendNTimes(' ', indent);
    try appendFmt(
        allocator,
        out,
        "let __runa_test_status_{s}_{d}_newline: CInt = #unsafe putchar :: __runa_test_status_{s}_{d}_newline_value :: call\n",
        .{ if (passed) "pass" else "fail", index, if (passed) "pass" else "fail", index },
    );
}

fn appendHarnessMain(
    allocator: Allocator,
    out: *std.array_list.Managed(u8),
    package_result: PackageTestResult,
) !void {
    try out.appendSlice("fn main() -> I32:\n");
    try out.appendSlice("    let runa_test_failures: I32 = 0\n");
    for (package_result.tests, 0..) |_, index| {
        try appendFmt(allocator, out, "    let runa_test_status_{d}: I32 = __runa_test_{d} :: :: call\n", .{ index, index });
        try appendFmt(allocator, out, "    runa_test_failures = runa_test_failures + runa_test_status_{d}\n", .{index});
    }
    try out.appendSlice("    return runa_test_failures\n");
}

fn appendSourceWithoutUserMain(
    out: *std.array_list.Managed(u8),
    root_source: []const u8,
    active: *const compiler.session.Session,
    root_path: []const u8,
) !void {
    const module = moduleBySourcePath(active, root_path) orelse {
        try out.appendSlice(root_source);
        return;
    };

    var cursor: usize = 0;
    var removed_any = false;
    for (module.hir.items.items) |item| {
        if (!isUserMainFunction(item)) continue;
        if (item.span.start < cursor or item.span.end > root_source.len) return error.InvalidTestHarnessSpan;
        try out.appendSlice(root_source[cursor..item.span.start]);
        cursor = trimFollowingBlankLines(root_source, item.span.end);
        removed_any = true;
    }

    if (!removed_any) {
        try out.appendSlice(root_source);
        return;
    }
    try out.appendSlice(root_source[cursor..]);
}

fn moduleBySourcePath(active: *const compiler.session.Session, root_path: []const u8) ?*const compiler.driver.ModulePipeline {
    for (active.pipeline.modules.items) |*module| {
        const file = active.pipeline.sources.get(module.parsed.module.file_id);
        if (std.mem.eql(u8, file.path, root_path)) return module;
    }
    return null;
}

fn moduleDeclaresName(active: *const compiler.session.Session, root_path: []const u8, name: []const u8) bool {
    const module = moduleBySourcePath(active, root_path) orelse return false;
    for (module.hir.items.items) |item| {
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

fn isUserMainFunction(item: compiler.hir.Item) bool {
    if (!std.mem.eql(u8, item.name, "main")) return false;
    if (hasAttribute(item.attributes, "test")) return false;
    return switch (item.kind) {
        .function, .suspend_function => true,
        else => false,
    };
}

fn hasAttribute(attributes: []const compiler.ast.Attribute, name: []const u8) bool {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return true;
    }
    return false;
}

fn trimFollowingBlankLines(source: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < source.len and (source[cursor] == '\r' or source[cursor] == '\n')) : (cursor += 1) {}
    return cursor;
}

fn rootModulePathForTest(active: *const compiler.session.Session, descriptor: TestDescriptor) ?[]const u8 {
    if (descriptor.item_id.index >= active.semantic_index.items.items.len) return null;
    const item_entry = active.semantic_index.items.items[descriptor.item_id.index];
    const test_module = active.pipeline.modules.items[item_entry.pipeline_module_index];
    for (active.pipeline.modules.items) |module| {
        if (module.package_index != test_module.package_index) continue;
        if (module.root_index != test_module.root_index) continue;
        if (module.module_path.len != 0) continue;
        const source_file = active.pipeline.sources.get(module.parsed.module.file_id);
        return source_file.path;
    }
    return null;
}

const ParsedHarnessStatusOutput = struct {
    statuses: []?bool,
    cleaned_stdout: ?[]u8,

    fn deinit(self: *ParsedHarnessStatusOutput, allocator: Allocator) void {
        allocator.free(self.statuses);
        if (self.cleaned_stdout) |bytes| allocator.free(bytes);
    }
};

fn parseHarnessStatusOutput(
    allocator: Allocator,
    package_result: PackageTestResult,
    stdout: ?[]const u8,
) !ParsedHarnessStatusOutput {
    const statuses = try allocator.alloc(?bool, package_result.tests.len);
    @memset(statuses, null);
    errdefer allocator.free(statuses);

    const bytes = stdout orelse return .{
        .statuses = statuses,
        .cleaned_stdout = null,
    };

    var cleaned = std.array_list.Managed(u8).init(allocator);
    errdefer cleaned.deinit();

    var index: usize = 0;
    while (index < bytes.len) {
        var matched = false;
        for (package_result.tests, 0..) |_, test_index| {
            const pass_marker = try statusMarker(allocator, test_index, true);
            const pass_matches = std.mem.startsWith(u8, bytes[index..], pass_marker);
            allocator.free(pass_marker);
            if (pass_matches) {
                statuses[test_index] = false;
                index = skipMarkerLineEnding(bytes, index + markerLength(test_index, true));
                matched = true;
                break;
            }

            const fail_marker = try statusMarker(allocator, test_index, false);
            const fail_matches = std.mem.startsWith(u8, bytes[index..], fail_marker);
            allocator.free(fail_marker);
            if (fail_matches) {
                statuses[test_index] = true;
                index = skipMarkerLineEnding(bytes, index + markerLength(test_index, false));
                matched = true;
                break;
            }
        }
        if (matched) continue;
        try cleaned.append(bytes[index]);
        index += 1;
    }

    return .{
        .statuses = statuses,
        .cleaned_stdout = try cleaned.toOwnedSlice(),
    };
}

fn skipMarkerLineEnding(bytes: []const u8, index: usize) usize {
    if (index < bytes.len and bytes[index] == '\r') {
        if (index + 1 < bytes.len and bytes[index + 1] == '\n') return index + 2;
        return index + 1;
    }
    if (index < bytes.len and bytes[index] == '\n') return index + 1;
    return index;
}

fn statusMarker(allocator: Allocator, index: usize, passed: bool) ![]const u8 {
    return std.fmt.allocPrint(allocator, "__RUNA_TEST_{s}_{d}__", .{ if (passed) "PASS" else "FAIL", index });
}

fn markerLength(index: usize, passed: bool) usize {
    var buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buffer, "__RUNA_TEST_{s}_{d}__", .{ if (passed) "PASS" else "FAIL", index }) catch unreachable;
    return marker.len;
}

fn appendFmt(allocator: Allocator, out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    try out.appendSlice(rendered);
}

fn relativePathText(root: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, path)) return ".";
    if (!std.mem.startsWith(u8, path, root)) return null;
    var relative = path[root.len..];
    if (relative.len != 0 and relative[0] != '/' and relative[0] != '\\') return null;
    while (relative.len != 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
    return relative;
}

fn openIterableDir(io: std.Io, path: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn isExcludedPackageDir(raw: []const u8) bool {
    const name = std.fs.path.basename(raw);
    return std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".git");
}

fn ensureParentDir(io: std.Io, full_path: []const u8) !void {
    const parent = std.fs.path.dirname(full_path) orelse return;
    try ensureDirPath(io, parent);
}

const HarnessArtifact = struct {
    path: []const u8,
    c_path: []const u8,

    fn deinit(self: HarnessArtifact, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.c_path);
    }
};

fn buildHarnessExecutable(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    package_name: []const u8,
    stem: []const u8,
    harness_path: []const u8,
    diagnostics: *compiler.diag.Bag,
) !HarnessArtifact {
    var active = try compiler.semantic.openFiles(allocator, io, &.{harness_path});
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items) |diagnostic| {
        try diagnostics.add(diagnostic.severity, diagnostic.code, diagnostic.span, "{s}", .{diagnostic.message});
    }
    if (active.pipeline.diagnostics.hasErrors()) return error.HarnessSemanticFailed;

    const out_dir = try std.fs.path.join(allocator, &.{ command_root, "target", compiler.target.hostName(), "debug", package_name, "__test" });
    defer allocator.free(out_dir);
    try ensureDirPath(io, out_dir);

    const c_name = try std.fmt.allocPrint(allocator, "{s}.c", .{stem});
    defer allocator.free(c_name);
    const c_path = try std.fs.path.join(allocator, &.{ out_dir, c_name });
    const exe_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, compiler.target.hostExecutableExtension() });
    defer allocator.free(exe_name);
    const exe_path = try std.fs.path.join(allocator, &.{ out_dir, exe_name });
    var keep_paths = false;
    defer if (!keep_paths) {
        allocator.free(c_path);
        allocator.free(exe_path);
    };

    var root_modules = std.array_list.Managed(*const compiler.backend_contract.LoweredModule).init(allocator);
    defer root_modules.deinit();
    for (active.pipeline.modules.items) |*module_pipeline| {
        if (module_pipeline.backend_contract) |*lowered| try root_modules.append(lowered);
    }
    if (root_modules.items.len == 0) return error.HarnessBackendMissing;

    var lowered_module = try compiler.backend_contract.mergeLoweredModules(allocator, .{
        .module_id = .{ .index = 0 },
        .target_name = compiler.target.hostName(),
        .output_kind = .bin,
    }, root_modules.items);
    defer compiler.backend_contract.deinitLoweredModule(allocator, &lowered_module);

    const c_source = compiler.codegen.emitCModule(allocator, stem, &lowered_module, .bin, diagnostics) catch return error.HarnessCodegenFailed;
    defer allocator.free(c_source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = c_path, .data = c_source });

    compiler.link.linkGeneratedC(allocator, io, c_path, exe_path, .bin, diagnostics) catch return error.HarnessLinkFailed;
    keep_paths = true;
    return .{ .path = exe_path, .c_path = c_path };
}

fn ensureDirPath(io: std.Io, absolute_path: []const u8) !void {
    var parts = std.mem.splitAny(u8, absolute_path, "/\\");
    var built = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer built.deinit();

    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try built.appendSlice("\\");
        first = false;
        try built.appendSlice(part);

        std.Io.Dir.cwd().createDir(io, built.items, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

test "harness process runs from package root" {
    if (!compiler.target.stage0WindowsHostSupported()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const package_root = try std.fs.path.join(std.testing.allocator, &.{ root, "package" });
    defer std.testing.allocator.free(package_root);
    try std.Io.Dir.cwd().createDir(std.testing.io, package_root, .default_dir);

    const helper_c = try std.fs.path.join(std.testing.allocator, &.{ root, "cwd_helper.c" });
    defer std.testing.allocator.free(helper_c);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = helper_c, .data =
        \\#include <stdio.h>
        \\#include <direct.h>
        \\int main(void) {
        \\    char buffer[4096];
        \\    if (_getcwd(buffer, sizeof(buffer)) == 0) return 2;
        \\    FILE *file = fopen("cwd-observed.txt", "wb");
        \\    if (file == 0) return 3;
        \\    fputs(buffer, file);
        \\    fclose(file);
        \\    return 0;
        \\}
        \\
    });

    const helper_exe = try std.fs.path.join(std.testing.allocator, &.{ root, "cwd_helper.exe" });
    defer std.testing.allocator.free(helper_exe);
    const cc_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "zig", "cc", helper_c, "-o", helper_exe },
        .cwd = .inherit,
    });
    defer std.testing.allocator.free(cc_result.stdout);
    defer std.testing.allocator.free(cc_result.stderr);
    switch (cc_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTestResult,
    }

    var run_result = try runHarnessProcess(std.testing.allocator, std.testing.io, helper_exe, package_root, false);
    defer run_result.deinit();
    switch (run_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTestResult,
    }

    const observed_path = try std.fs.path.join(std.testing.allocator, &.{ package_root, "cwd-observed.txt" });
    defer std.testing.allocator.free(observed_path);
    const observed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, observed_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(observed);
    const expected = try std.fs.path.resolve(std.testing.allocator, &.{package_root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, std.mem.trim(u8, observed, " \t\r\n"));
}
