const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const toolchain = @import("toolchain");
const Allocator = std.mem.Allocator;

const BenchmarkCase = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,

    fn averageNs(self: BenchmarkCase) u64 {
        if (self.iterations == 0) return 0;
        return self.total_ns / self.iterations;
    }
};

const Iterations = struct {
    cold_parse: usize = 20,
    check_graph: usize = 5,
    incremental: usize = 40,
};

const required_incremental_speedup_x100: u64 = 110;

pub fn main(init: std.process.Init) !void {
    return runBenchmarks(init, std.heap.smp_allocator, "smp_allocator");
}

fn runBenchmarks(init: std.process.Init, allocator: Allocator, allocator_name: []const u8) !void {
    const source_old = try buildBenchmarkSource(allocator, 192, 2, 7);
    defer allocator.free(source_old);
    const source_nested_edit = try buildBenchmarkSource(allocator, 192, 22, 7);
    defer allocator.free(source_nested_edit);
    const source_top_level_edit = try buildBenchmarkSource(allocator, 192, 2, 77);
    defer allocator.free(source_top_level_edit);

    const nested_edit = TextReplacement{
        .start = findRequired(source_old, "return 2") + "return ".len,
        .old_len = 1,
        .replacement = "22",
    };
    const top_level_edit = TextReplacement{
        .start = findRequired(source_old, "return 7") + "return ".len,
        .old_len = 1,
        .replacement = "77",
    };

    const counts = parseIterationArgs(init) catch Iterations{};

    const cold_parse = try measureColdParse(allocator, init.io, source_old, counts.cold_parse);
    const nested_incremental = try measureIncrementalReparse(
        allocator,
        init.io,
        source_old,
        source_nested_edit,
        nested_edit,
        "small-edit incremental reparse",
        counts.incremental,
    );
    const nested_full_parse = try measureFullParse(
        allocator,
        init.io,
        source_nested_edit,
        "small-edit full parse baseline",
        counts.incremental,
    );
    const top_level_incremental = try measureIncrementalReparse(
        allocator,
        init.io,
        source_old,
        source_top_level_edit,
        top_level_edit,
        "top-level incremental reparse",
        counts.incremental,
    );
    const top_level_full_parse = try measureFullParse(
        allocator,
        init.io,
        source_top_level_edit,
        "top-level full parse baseline",
        counts.incremental,
    );

    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(cwd);
    const workspace_root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "parser-frontend-bench" });
    defer allocator.free(workspace_root);
    try ensureBenchmarkWorkspace(allocator, init.io, workspace_root, source_old);
    const check_graph = try measureCheckGraph(allocator, init.io, workspace_root, counts.check_graph);

    std.debug.print("parser/frontend benchmarks\n", .{});
    std.debug.print("allocator: {s}\n", .{allocator_name});
    printCase(cold_parse);
    printCase(check_graph);
    printCase(nested_incremental);
    printCase(nested_full_parse);
    printSpeedup("small-edit incremental speedup", nested_full_parse, nested_incremental);
    printCase(top_level_incremental);
    printCase(top_level_full_parse);
    printSpeedup("top-level incremental speedup", top_level_full_parse, top_level_incremental);

    if (speedupX100(nested_full_parse, nested_incremental) < required_incremental_speedup_x100) {
        return error.SmallEditIncrementalTooSlow;
    }
    if (speedupX100(top_level_full_parse, top_level_incremental) < required_incremental_speedup_x100) {
        return error.TopLevelIncrementalTooSlow;
    }
}

const TextReplacement = struct {
    start: usize,
    old_len: usize,
    replacement: []const u8,
};

fn parseIterationArgs(init: std.process.Init) !Iterations {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var counts = Iterations{};
    if (args.len >= 2) counts.cold_parse = try std.fmt.parseInt(usize, args[1], 10);
    if (args.len >= 3) counts.incremental = try std.fmt.parseInt(usize, args[2], 10);
    if (args.len >= 4) counts.check_graph = try std.fmt.parseInt(usize, args[3], 10);
    return counts;
}

fn buildBenchmarkSource(
    allocator: Allocator,
    helper_count: usize,
    nested_else_value: usize,
    top_level_return_value: usize,
) ![]u8 {
    var source_text = array_list.Managed(u8).init(allocator);
    defer source_text.deinit();

    for (0..helper_count) |index| {
        const helper = try std.fmt.allocPrint(allocator,
            \\fn helper_{d}(value: I32) -> I32:
            \\    return value
            \\
        , .{index});
        defer allocator.free(helper);
        try source_text.appendSlice(helper);
    }

    const nested = try std.fmt.allocPrint(allocator,
        \\fn nested_target(flag: Bool) -> I32:
        \\    return 0
        \\    select:
        \\        when flag =>
        \\            return 1
        \\        else =>
        \\            return {d}
        \\    return 3
        \\
        \\fn top_level_target() -> I32:
        \\    return {d}
        \\
        \\fn main() -> I32:
        \\    return 0
        \\
    , .{ nested_else_value, top_level_return_value });
    defer allocator.free(nested);
    try source_text.appendSlice(nested);

    for (0..helper_count) |index| {
        const helper = try std.fmt.allocPrint(allocator,
            \\fn suffix_helper_{d}(value: I32) -> I32:
            \\    return value
            \\
        , .{index});
        defer allocator.free(helper);
        try source_text.appendSlice(helper);
    }

    return try source_text.toOwnedSlice();
}

fn measureColdParse(allocator: Allocator, io: std.Io, source_text: []const u8, iterations: usize) !BenchmarkCase {
    var table = compiler.source.Table.init(allocator);
    defer table.deinit();
    const file_id = try table.addVirtualFile("parser-bench.rna", source_text);
    const file = table.get(file_id);

    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        var diagnostics = compiler.diag.Bag.init(allocator);
        defer diagnostics.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        var parsed = try compiler.parse.parseFile(allocator, file, &diagnostics);
        const elapsed = elapsedNs(start, std.Io.Timestamp.now(io, .awake));
        parsed.deinit(allocator);

        if (diagnostics.hasErrors()) return error.InvalidBenchmarkSource;
        total_ns += elapsed;
    }

    return .{
        .name = "full-file cold parse",
        .iterations = iterations,
        .total_ns = total_ns,
    };
}

fn measureFullParse(
    allocator: Allocator,
    io: std.Io,
    source_text: []const u8,
    name: []const u8,
    iterations: usize,
) !BenchmarkCase {
    var table = compiler.source.Table.init(allocator);
    defer table.deinit();
    const file_id = try table.addVirtualFile("parser-bench-edited.rna", source_text);
    const file = table.get(file_id);

    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        var diagnostics = compiler.diag.Bag.init(allocator);
        defer diagnostics.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        var parsed = try compiler.parse.parseFile(allocator, file, &diagnostics);
        const elapsed = elapsedNs(start, std.Io.Timestamp.now(io, .awake));
        parsed.deinit(allocator);

        if (diagnostics.hasErrors()) return error.InvalidBenchmarkSource;
        total_ns += elapsed;
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
    };
}

fn measureIncrementalReparse(
    allocator: Allocator,
    io: std.Io,
    old_source: []const u8,
    new_source: []const u8,
    replacement: TextReplacement,
    name: []const u8,
    iterations: usize,
) !BenchmarkCase {
    var table = compiler.source.Table.init(allocator);
    defer table.deinit();

    const old_id = try table.addVirtualFile("parser-bench-old.rna", old_source);
    const new_id = try table.addVirtualFile("parser-bench-new.rna", new_source);
    const old_file = table.get(old_id);
    const new_file = table.get(new_id);

    var parse_diagnostics = compiler.diag.Bag.init(allocator);
    defer parse_diagnostics.deinit();
    var parsed = try compiler.parse.parseFile(allocator, old_file, &parse_diagnostics);
    defer parsed.deinit(allocator);
    if (parse_diagnostics.hasErrors()) return error.InvalidBenchmarkSource;

    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        var diagnostics = compiler.diag.Bag.init(allocator);
        defer diagnostics.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        var reparsed = try compiler.parse.reparseFile(
            allocator,
            &parsed,
            new_file,
            &.{
                .{
                    .start = replacement.start,
                    .end = replacement.start + replacement.old_len,
                    .replacement = replacement.replacement,
                },
            },
            &diagnostics,
        );
        const elapsed = elapsedNs(start, std.Io.Timestamp.now(io, .awake));
        reparsed.deinit(allocator);

        if (diagnostics.hasErrors()) return error.InvalidBenchmarkSource;
        total_ns += elapsed;
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
    };
}

fn measureCheckGraph(allocator: Allocator, io: std.Io, workspace_root: []const u8, iterations: usize) !BenchmarkCase {
    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        var graph = try toolchain.workspace.loadGraphAtPath(allocator, io, workspace_root);
        defer graph.deinit();
        var compiler_graph = try toolchain.workspace.toCompilerGraph(allocator, &graph);
        defer compiler_graph.deinit();
        var active = try compiler.semantic.openGraph(allocator, io, compiler_graph.graph);
        defer active.deinit();
        const elapsed = elapsedNs(start, std.Io.Timestamp.now(io, .awake));

        if (active.pipeline.diagnostics.hasErrors()) return error.InvalidBenchmarkWorkspace;
        total_ns += elapsed;
    }

    return .{
        .name = "full frontend query check",
        .iterations = iterations,
        .total_ns = total_ns,
    };
}

fn ensureBenchmarkWorkspace(allocator: Allocator, io: std.Io, workspace_root: []const u8, source_text: []const u8) !void {
    const parent = std.fs.path.dirname(workspace_root) orelse return error.InvalidBenchmarkWorkspace;
    std.Io.Dir.cwd().createDir(io, parent, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().createDir(io, workspace_root, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const manifest_path = try std.fs.path.join(allocator, &.{ workspace_root, "runa.toml" });
    defer allocator.free(manifest_path);
    const main_path = try std.fs.path.join(allocator, &.{ workspace_root, "main.rna" });
    defer allocator.free(main_path);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data =
        \\[package]
        \\name = "parser_frontend_bench"
        \\version = "0.1.0"
        \\edition = "2026"
        \\lang_version = "0.00"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = main_path,
        .data = source_text,
    });
}

fn findRequired(haystack: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, haystack, needle) orelse @panic("missing benchmark marker");
}

fn printCase(case: BenchmarkCase) void {
    std.debug.print("  {s}: {d} iterations, avg {d} us\n", .{
        case.name,
        case.iterations,
        case.averageNs() / std.time.ns_per_us,
    });
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(end).nanoseconds);
}

fn printSpeedup(label: []const u8, baseline: BenchmarkCase, candidate: BenchmarkCase) void {
    if (candidate.averageNs() == 0) return;
    const speedup_x100 = speedupX100(baseline, candidate);
    std.debug.print("  {s}: {d}.{d:0>2}x\n", .{
        label,
        speedup_x100 / 100,
        speedup_x100 % 100,
    });
}

fn speedupX100(baseline: BenchmarkCase, candidate: BenchmarkCase) u64 {
    if (candidate.averageNs() == 0) return 0;
    return (baseline.averageNs() * 100) / candidate.averageNs();
}
