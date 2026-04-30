const std = @import("std");
const build_command = @import("../build/root.zig");
const check_command = @import("../check/root.zig");
const fmt_command = @import("../fmt/root.zig");
const pkgcmd = @import("../pkgcmd/root.zig");
const test_command = @import("../test/root.zig");
const context = @import("context.zig");
const writer = @import("writer.zig");

pub const summary = "Canonical runa CLI shell.";
pub const Writer = writer;
pub const Context = context;

pub const CommandClass = enum {
    standardized,
    reserved_later,
};

pub const CommandContextKind = enum {
    standalone,
    manifest_rooted,
};

pub const Command = enum {
    new,
    build,
    check,
    @"test",
    fmt,
    add,
    remove,
    import,
    vendor,
    publish,
    doc,
    review,
    repair,

    pub fn name(self: Command) []const u8 {
        return commandSpec(self).name;
    }

    pub fn class(self: Command) CommandClass {
        return commandSpec(self).class;
    }

    pub fn contextKind(self: Command) CommandContextKind {
        return commandSpec(self).context_kind;
    }

    pub fn needsRegistryConfig(self: Command) bool {
        return switch (self) {
            .import, .vendor, .publish => true,
            else => false,
        };
    }

    pub fn needsGlobalStore(self: Command) bool {
        return switch (self) {
            .import => true,
            else => false,
        };
    }

    pub fn needsTargetPackage(self: Command) bool {
        return switch (self) {
            .add, .remove, .vendor, .publish => true,
            else => false,
        };
    }
};

pub const CommandSpec = struct {
    command: Command,
    name: []const u8,
    class: CommandClass,
    context_kind: CommandContextKind,
    description: []const u8,
};

pub const command_specs = [_]CommandSpec{
    .{ .command = .new, .name = "new", .class = .standardized, .context_kind = .standalone, .description = "create a package scaffold" },
    .{ .command = .build, .name = "build", .class = .standardized, .context_kind = .manifest_rooted, .description = "build selected products" },
    .{ .command = .check, .name = "check", .class = .standardized, .context_kind = .manifest_rooted, .description = "run semantic checks" },
    .{ .command = .@"test", .name = "test", .class = .standardized, .context_kind = .manifest_rooted, .description = "discover and run tests" },
    .{ .command = .fmt, .name = "fmt", .class = .standardized, .context_kind = .manifest_rooted, .description = "format source files" },
    .{ .command = .add, .name = "add", .class = .standardized, .context_kind = .manifest_rooted, .description = "add one dependency" },
    .{ .command = .remove, .name = "remove", .class = .standardized, .context_kind = .manifest_rooted, .description = "remove one dependency" },
    .{ .command = .import, .name = "import", .class = .standardized, .context_kind = .standalone, .description = "import one registry source into the global store" },
    .{ .command = .vendor, .name = "vendor", .class = .standardized, .context_kind = .manifest_rooted, .description = "vendor one registry source into the workspace" },
    .{ .command = .publish, .name = "publish", .class = .standardized, .context_kind = .manifest_rooted, .description = "publish one package to a local registry" },
    .{ .command = .doc, .name = "doc", .class = .reserved_later, .context_kind = .standalone, .description = "reserved documentation command" },
    .{ .command = .review, .name = "review", .class = .reserved_later, .context_kind = .standalone, .description = "reserved review command" },
    .{ .command = .repair, .name = "repair", .class = .reserved_later, .context_kind = .standalone, .description = "reserved repair command" },
};

pub const ParseFailure = struct {
    message: []const u8,
};

pub const ParsedInvocation = union(enum) {
    top_level_help,
    version,
    command_help: Command,
    command: ParsedCommand,
};

pub const ParsedCommand = union(Command) {
    new: NewOptions,
    build: BuildOptions,
    check: void,
    @"test": TestOptions,
    fmt: FmtOptions,
    add: DependencyEditOptions,
    remove: RemoveOptions,
    import: ImportOptions,
    vendor: VendorOptions,
    publish: PublishOptions,
    doc: void,
    review: void,
    repair: void,
};

pub const NewOptions = struct {
    name: []const u8,
    lib: bool = false,
};

pub const BuildOptions = struct {
    release: bool = false,
    package: ?[]const u8 = null,
    product: ?[]const u8 = null,
    bin: ?[]const u8 = null,
    cdylib: ?[]const u8 = null,
};

pub const TestOptions = struct {
    parallel: bool = false,
    no_capture: bool = false,
};

pub const FmtOptions = struct {
    check: bool = false,
};

pub const DependencyEditOptions = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
};

pub const RemoveOptions = struct {
    name: []const u8,
};

pub const ImportOptions = struct {
    name: []const u8,
    version: []const u8,
    registry: ?[]const u8 = null,
};

pub const VendorOptions = struct {
    name: []const u8,
    version: []const u8,
    registry: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
};

pub const PublishOptions = struct {
    registry: []const u8,
    artifacts: bool = false,
};

pub const ParseResult = union(enum) {
    ok: ParsedInvocation,
    failure: ParseFailure,
};

pub const CliOutcome = union(enum) {
    parsed_success,
    usage_failure: []const u8,
    reserved_unimplemented: Command,
    unimplemented: Command,
    command_failure: []const u8,
};

pub const Error = error{
    UsageFailure,
    ReservedUnimplemented,
    Unimplemented,
    CommandFailure,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const outcome = try run(arena, init.io, args);
    switch (outcome) {
        .parsed_success => return,
        .usage_failure,
        .reserved_unimplemented,
        .unimplemented,
        .command_failure,
        => std.process.exit(1),
    }
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !CliOutcome {
    return runWithOutput(allocator, io, argv, .emit, null);
}

pub fn runQuietForTest(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !CliOutcome {
    return runWithOutput(allocator, io, argv, .suppress, null);
}

pub fn runQuietForTestWithEnvMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    env_map: *const std.process.Environ.Map,
) !CliOutcome {
    return runWithOutput(allocator, io, argv, .suppress, env_map);
}

const OutputMode = enum {
    emit,
    suppress,
};

fn runWithOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    output: OutputMode,
    env_map: ?*const std.process.Environ.Map,
) !CliOutcome {
    const args = if (argv.len == 0) argv else argv[1..];
    const parsed = try parseArgs(allocator, args);
    switch (parsed) {
        .failure => |failure| {
            try writeLineIfEmitting(output, io, .stderr, failure.message);
            return .{ .usage_failure = failure.message };
        },
        .ok => |invocation| return executeParsed(allocator, io, invocation, output, env_map),
    }
}

pub fn parseSubcommand(raw: []const u8) ?Command {
    for (command_specs) |spec| {
        if (std.mem.eql(u8, raw, spec.name)) return spec.command;
    }
    return null;
}

pub fn commandSpec(command: Command) CommandSpec {
    for (command_specs) |spec| {
        if (spec.command == command) return spec;
    }
    unreachable;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    if (args.len == 0) return .{ .ok = .top_level_help };

    const first = args[0];
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        if (args.len != 1) return fail(allocator, "top-level help does not accept extra arguments", .{});
        return .{ .ok = .top_level_help };
    }
    if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "--version")) {
        if (args.len != 1) return fail(allocator, "top-level version does not accept extra arguments", .{});
        return .{ .ok = .version };
    }

    const command = parseSubcommand(first) orelse return fail(allocator, "unknown subcommand '{s}'", .{first});
    const rest = args[1..];
    if (rest.len == 1 and std.mem.eql(u8, rest[0], "--help")) {
        return .{ .ok = .{ .command_help = command } };
    }
    if (command.class() == .reserved_later) {
        if (rest.len != 0) return fail(allocator, "reserved command '{s}' does not accept arguments yet", .{command.name()});
        return .{ .ok = .{ .command = reservedParsed(command) } };
    }

    const parsed_command = parseCommand(allocator, command, rest) catch |err| {
        return parseFailureFromError(allocator, err);
    };
    return .{ .ok = .{ .command = parsed_command } };
}

fn executeParsed(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: ParsedInvocation,
    output: OutputMode,
    env_map: ?*const std.process.Environ.Map,
) !CliOutcome {
    switch (invocation) {
        .top_level_help => {
            try writeLinesIfEmitting(output, io, .stdout, &top_level_help_lines);
            return .parsed_success;
        },
        .version => {
            try writeLineIfEmitting(output, io, .stdout, "runa 2026.0.01 stage0");
            return .parsed_success;
        },
        .command_help => |command| {
            if (output == .emit) try renderCommandHelp(io, command);
            return .parsed_success;
        },
        .command => |command| {
            const tag = std.meta.activeTag(command);
            if (tag.class() == .reserved_later) {
                const line = try std.fmt.allocPrint(allocator, "runa {s}: reserved for later and unimplemented", .{tag.name()});
                try writeLineIfEmitting(output, io, .stderr, line);
                return .{ .reserved_unimplemented = tag };
            }

            var command_context = context.buildWithEnvMap(allocator, io, tag, env_map) catch |err| {
                const line = try std.fmt.allocPrint(allocator, "runa {s}: {s}", .{ tag.name(), @errorName(err) });
                try writeLineIfEmitting(output, io, .stderr, line);
                return .{ .command_failure = line };
            };
            defer command_context.deinit();

            switch (command) {
                .new => |options| return executeNew(allocator, io, &command_context, options, output),
                .build => |options| return executeBuild(allocator, io, &command_context, options, output),
                .check => return executeCheck(allocator, io, &command_context, output),
                .@"test" => |options| return executeTest(allocator, io, &command_context, options, output),
                .fmt => |options| return executeFmt(allocator, io, &command_context, options, output),
                .add => |options| return executeAdd(allocator, io, &command_context, options, output),
                .remove => |options| return executeRemove(allocator, io, &command_context, options, output),
                .import => |options| return executeImport(allocator, io, &command_context, options, output),
                .vendor => |options| return executeVendor(allocator, io, &command_context, options, output),
                .publish => |options| return executePublish(allocator, io, &command_context, options, output),
                else => {},
            }

            const line = try std.fmt.allocPrint(allocator, "runa {s}: unimplemented", .{tag.name()});
            try writeLineIfEmitting(output, io, .stderr, line);
            return .{ .unimplemented = tag };
        },
    }
}

fn executeNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: NewOptions,
    output: OutputMode,
) !CliOutcome {
    const standalone = switch (command_context.*) {
        .standalone => |*value| value,
        .manifest_rooted => return .{ .command_failure = "runa new: invalid context" },
    };
    var result = pkgcmd.runNew(allocator, io, standalone, .{ .name = options.name, .lib = options.lib }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa new: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit(allocator);

    const line = try std.fmt.allocPrint(allocator, "runa new: ok ({s}, {d} file(s))", .{ result.package_dir, result.files_written });
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeBuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: BuildOptions,
    output: OutputMode,
) !CliOutcome {
    var result = build_command.buildCommandContext(allocator, io, command_context, .{
        .release = options.release,
        .package = options.package,
        .product = options.product,
        .bin = options.bin,
        .cdylib = options.cdylib,
    }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa build: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit();

    if (output == .emit) {
        try writer.renderDiagnostics(allocator, io, result.active.pipeline.diagnostics, &result.active.pipeline.sources);
    }

    if (result.hasErrors()) {
        const line = try std.fmt.allocPrint(allocator, "runa build: {d} error(s)", .{result.errorCount()});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    }

    const line = try std.fmt.allocPrint(allocator, "runa build: ok ({s}, {s}, {d} artifact(s))", .{
        result.selected_target,
        result.mode.name(),
        result.artifacts.items.len,
    });
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: DependencyEditOptions,
    output: OutputMode,
) !CliOutcome {
    const manifest_rooted = switch (command_context.*) {
        .manifest_rooted => |*value| value,
        .standalone => return .{ .command_failure = "runa add: invalid context" },
    };
    var result = pkgcmd.runAdd(allocator, io, manifest_rooted, .{
        .name = options.name,
        .version = options.version,
        .path = options.path,
        .registry = options.registry,
        .edition = options.edition,
        .lang_version = options.lang_version,
    }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa add: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit(allocator);
    const line = try std.fmt.allocPrint(allocator, "runa add: ok ({s})", .{result.manifest_path});
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: RemoveOptions,
    output: OutputMode,
) !CliOutcome {
    const manifest_rooted = switch (command_context.*) {
        .manifest_rooted => |*value| value,
        .standalone => return .{ .command_failure = "runa remove: invalid context" },
    };
    var result = pkgcmd.runRemove(allocator, io, manifest_rooted, .{ .name = options.name }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa remove: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit(allocator);
    const line = try std.fmt.allocPrint(allocator, "runa remove: ok ({s})", .{result.manifest_path});
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: ImportOptions,
    output: OutputMode,
) !CliOutcome {
    const standalone = switch (command_context.*) {
        .standalone => |*value| value,
        .manifest_rooted => return .{ .command_failure = "runa import: invalid context" },
    };
    var result = pkgcmd.runImport(allocator, io, standalone, .{
        .name = options.name,
        .version = options.version,
        .registry = options.registry,
    }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa import: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit(allocator);
    const line = try std.fmt.allocPrint(allocator, "runa import: ok ({s})", .{result.store_entry_root});
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeVendor(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: VendorOptions,
    output: OutputMode,
) !CliOutcome {
    const manifest_rooted = switch (command_context.*) {
        .manifest_rooted => |*value| value,
        .standalone => return .{ .command_failure = "runa vendor: invalid context" },
    };
    var result = pkgcmd.runVendor(allocator, io, manifest_rooted, .{
        .name = options.name,
        .version = options.version,
        .registry = options.registry,
        .edition = options.edition,
        .lang_version = options.lang_version,
    }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa vendor: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit(allocator);
    const line = try std.fmt.allocPrint(allocator, "runa vendor: ok ({s})", .{result.vendor_root});
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executePublish(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: PublishOptions,
    output: OutputMode,
) !CliOutcome {
    const manifest_rooted = switch (command_context.*) {
        .manifest_rooted => |*value| value,
        .standalone => return .{ .command_failure = "runa publish: invalid context" },
    };
    var result = pkgcmd.runPublish(allocator, io, manifest_rooted, .{
        .registry = options.registry,
        .artifacts = options.artifacts,
    }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa publish: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit(allocator);
    const line = try std.fmt.allocPrint(
        allocator,
        "runa publish: ok ({s}, {d} source file(s), {d} artifact(s))",
        .{ result.source_root, result.copied_source_files, result.published_artifacts },
    );
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: TestOptions,
    output: OutputMode,
) !CliOutcome {
    var result = test_command.runCommandContext(allocator, io, command_context, .{
        .parallel = options.parallel,
        .no_capture = options.no_capture,
    }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa test: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit();

    if (output == .emit) {
        try writer.renderDiagnostics(allocator, io, result.active.pipeline.diagnostics, &result.active.pipeline.sources);
    }

    for (result.progress.items) |progress| {
        const line = try std.fmt.allocPrint(
            allocator,
            "runa test: {s} {s}::{s}",
            .{
                if (progress.passed) "ok" else "failed",
                progress.package_name,
                progress.function_name,
            },
        );
        try writeLineIfEmitting(output, io, .stderr, line);
    }

    for (result.package_summaries.items) |package_summary| {
        const line = try std.fmt.allocPrint(
            allocator,
            "runa test package {s}: discovered={d} executed={d} passed={d} failed={d} harness_failures={d}",
            .{
                package_summary.package_name,
                package_summary.discovered,
                package_summary.executed,
                package_summary.passed,
                package_summary.failed,
                package_summary.harness_failures,
            },
        );
        try writeLineIfEmitting(output, io, .stdout, line);
    }

    const summary_line = try std.fmt.allocPrint(
        allocator,
        "runa test: discovered={d} executed={d} passed={d} failed={d} harness_failures={d}",
        .{
            result.summary.discovered,
            result.summary.executed,
            result.summary.passed,
            result.summary.failed,
            result.summary.harness_failures,
        },
    );
    try writeLineIfEmitting(output, io, .stdout, summary_line);

    if (result.failed()) return .{ .command_failure = summary_line };
    return .parsed_success;
}

fn executeFmt(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    options: FmtOptions,
    output: OutputMode,
) !CliOutcome {
    var result = fmt_command.formatCommandContext(allocator, io, command_context, .{ .check = options.check }) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa fmt: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit();

    if (output == .emit) {
        try writer.renderDiagnostics(allocator, io, result.active.pipeline.diagnostics, &result.active.pipeline.sources);
    }

    if (result.failed()) {
        const line = if (result.check_mismatches != 0)
            try std.fmt.allocPrint(allocator, "runa fmt: {d} file(s) need formatting", .{result.check_mismatches})
        else
            try std.fmt.allocPrint(allocator, "runa fmt: {d} blocking format error(s)", .{result.blocking_errors});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    }

    const line = try std.fmt.allocPrint(allocator, "runa fmt: ok ({d} file(s), {d} changed)", .{
        result.formatted_files,
        result.changed_files,
    });
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn executeCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    command_context: *const context.CommandContext,
    output: OutputMode,
) !CliOutcome {
    var result = check_command.runContext(allocator, io, command_context) catch |err| {
        const line = try std.fmt.allocPrint(allocator, "runa check: {s}", .{@errorName(err)});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    };
    defer result.deinit();

    if (output == .emit) {
        try writer.renderDiagnostics(allocator, io, result.active.pipeline.diagnostics, &result.active.pipeline.sources);
    }

    if (result.hasErrors()) {
        const line = try std.fmt.allocPrint(allocator, "runa check: {d} error(s)", .{result.errorCount()});
        try writeLineIfEmitting(output, io, .stderr, line);
        return .{ .command_failure = line };
    }

    const line = try std.fmt.allocPrint(allocator, "runa check: ok ({d} package(s), {d} product(s), {d} source file(s))", .{
        result.checkedPackageCount(),
        result.checkedProductCount(),
        result.checkedSourceFileCount(),
    });
    try writeLineIfEmitting(output, io, .stdout, line);
    return .parsed_success;
}

fn writeLineIfEmitting(output: OutputMode, io: std.Io, channel: writer.Channel, line: []const u8) !void {
    if (output == .emit) try writer.writeLine(io, channel, line);
}

fn writeLinesIfEmitting(output: OutputMode, io: std.Io, channel: writer.Channel, lines: []const []const u8) !void {
    if (output == .emit) try writer.writeLines(io, channel, lines);
}

fn parseCommand(allocator: std.mem.Allocator, command: Command, args: []const []const u8) !ParsedCommand {
    return switch (command) {
        .new => .{ .new = try parseNew(allocator, args) },
        .build => .{ .build = try parseBuild(allocator, args) },
        .check => blk: {
            try rejectArgs(allocator, command, args);
            break :blk .{ .check = {} };
        },
        .@"test" => .{ .@"test" = try parseTest(allocator, args) },
        .fmt => .{ .fmt = try parseFmt(allocator, args) },
        .add => .{ .add = try parseDependencyEdit(allocator, command, args) },
        .remove => .{ .remove = try parseRemove(allocator, args) },
        .import => .{ .import = try parseImport(allocator, args) },
        .vendor => .{ .vendor = try parseVendor(allocator, args) },
        .publish => .{ .publish = try parsePublish(allocator, args) },
        .doc, .review, .repair => reservedParsed(command),
    };
}

fn reservedParsed(command: Command) ParsedCommand {
    return switch (command) {
        .doc => .{ .doc = {} },
        .review => .{ .review = {} },
        .repair => .{ .repair = {} },
        else => unreachable,
    };
}

fn parseNew(allocator: std.mem.Allocator, args: []const []const u8) !NewOptions {
    var parser = ArgParser.init(allocator, .new, args);
    var options = NewOptions{ .name = "" };
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| {
            if (std.mem.eql(u8, flag.name, "lib")) {
                try parser.setBool(&options.lib, flag);
            } else return parser.unknownFlag(flag);
        } else {
            try parser.setPositional(&options.name, arg.value, "package name");
        }
    }
    if (options.name.len == 0) return parser.missing("package name");
    return options;
}

fn parseBuild(allocator: std.mem.Allocator, args: []const []const u8) !BuildOptions {
    var parser = ArgParser.init(allocator, .build, args);
    var options = BuildOptions{};
    while (try parser.next()) |arg| {
        const flag = arg.flag orelse return parser.unexpectedPositional(arg.value);
        if (std.mem.eql(u8, flag.name, "release")) try parser.setBool(&options.release, flag) else if (std.mem.eql(u8, flag.name, "package")) try parser.setValue(&options.package, flag) else if (std.mem.eql(u8, flag.name, "product")) try parser.setValue(&options.product, flag) else if (std.mem.eql(u8, flag.name, "bin")) try parser.setValue(&options.bin, flag) else if (std.mem.eql(u8, flag.name, "cdylib")) try parser.setValue(&options.cdylib, flag) else return parser.unknownFlag(flag);
    }
    const selectors = @intFromBool(options.product != null) + @intFromBool(options.bin != null) + @intFromBool(options.cdylib != null);
    if (selectors > 1) return parser.fail("conflicting product selectors", .{});
    return options;
}

fn parseTest(allocator: std.mem.Allocator, args: []const []const u8) !TestOptions {
    var parser = ArgParser.init(allocator, .@"test", args);
    var options = TestOptions{};
    while (try parser.next()) |arg| {
        const flag = arg.flag orelse return parser.unexpectedPositional(arg.value);
        if (std.mem.eql(u8, flag.name, "parallel")) try parser.setBool(&options.parallel, flag) else if (std.mem.eql(u8, flag.name, "no-capture")) try parser.setBool(&options.no_capture, flag) else return parser.unknownFlag(flag);
    }
    return options;
}

fn parseFmt(allocator: std.mem.Allocator, args: []const []const u8) !FmtOptions {
    var parser = ArgParser.init(allocator, .fmt, args);
    var options = FmtOptions{};
    while (try parser.next()) |arg| {
        const flag = arg.flag orelse return parser.unexpectedPositional(arg.value);
        if (std.mem.eql(u8, flag.name, "check")) try parser.setBool(&options.check, flag) else return parser.unknownFlag(flag);
    }
    return options;
}

fn parseDependencyEdit(allocator: std.mem.Allocator, command: Command, args: []const []const u8) !DependencyEditOptions {
    var parser = ArgParser.init(allocator, command, args);
    var options = DependencyEditOptions{ .name = "" };
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| {
            if (std.mem.eql(u8, flag.name, "version")) try parser.setValue(&options.version, flag) else if (std.mem.eql(u8, flag.name, "path")) try parser.setValue(&options.path, flag) else if (std.mem.eql(u8, flag.name, "registry")) try parser.setValue(&options.registry, flag) else if (std.mem.eql(u8, flag.name, "edition")) try parser.setValue(&options.edition, flag) else if (std.mem.eql(u8, flag.name, "lang-version")) try parser.setValue(&options.lang_version, flag) else return parser.unknownFlag(flag);
        } else {
            try parser.setPositional(&options.name, arg.value, "package name");
        }
    }
    if (options.name.len == 0) return parser.missing("package name");
    if (options.path) |_| {
        if (options.registry != null) return parser.fail("--path cannot be combined with --registry", .{});
    } else if (options.version == null) {
        return parser.missing("--version");
    }
    return options;
}

fn parseRemove(allocator: std.mem.Allocator, args: []const []const u8) !RemoveOptions {
    var parser = ArgParser.init(allocator, .remove, args);
    var options = RemoveOptions{ .name = "" };
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| return parser.unknownFlag(flag);
        try parser.setPositional(&options.name, arg.value, "package name");
    }
    if (options.name.len == 0) return parser.missing("package name");
    return options;
}

fn parseImport(allocator: std.mem.Allocator, args: []const []const u8) !ImportOptions {
    var parser = ArgParser.init(allocator, .import, args);
    var name: []const u8 = "";
    var version: ?[]const u8 = null;
    var registry: ?[]const u8 = null;
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| {
            if (std.mem.eql(u8, flag.name, "version")) try parser.setValue(&version, flag) else if (std.mem.eql(u8, flag.name, "registry")) try parser.setValue(&registry, flag) else return parser.unknownFlag(flag);
        } else {
            try parser.setPositional(&name, arg.value, "package name");
        }
    }
    if (name.len == 0) return parser.missing("package name");
    return .{ .name = name, .version = version orelse return parser.missing("--version"), .registry = registry };
}

fn parseVendor(allocator: std.mem.Allocator, args: []const []const u8) !VendorOptions {
    var parser = ArgParser.init(allocator, .vendor, args);
    var name: []const u8 = "";
    var version: ?[]const u8 = null;
    var registry: ?[]const u8 = null;
    var edition: ?[]const u8 = null;
    var lang_version: ?[]const u8 = null;
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| {
            if (std.mem.eql(u8, flag.name, "version")) try parser.setValue(&version, flag) else if (std.mem.eql(u8, flag.name, "registry")) try parser.setValue(&registry, flag) else if (std.mem.eql(u8, flag.name, "edition")) try parser.setValue(&edition, flag) else if (std.mem.eql(u8, flag.name, "lang-version")) try parser.setValue(&lang_version, flag) else return parser.unknownFlag(flag);
        } else {
            try parser.setPositional(&name, arg.value, "package name");
        }
    }
    if (name.len == 0) return parser.missing("package name");
    return .{
        .name = name,
        .version = version orelse return parser.missing("--version"),
        .registry = registry,
        .edition = edition,
        .lang_version = lang_version,
    };
}

fn parsePublish(allocator: std.mem.Allocator, args: []const []const u8) !PublishOptions {
    var parser = ArgParser.init(allocator, .publish, args);
    var options = PublishOptions{ .registry = "" };
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| {
            if (std.mem.eql(u8, flag.name, "artifacts")) try parser.setBool(&options.artifacts, flag) else return parser.unknownFlag(flag);
        } else {
            try parser.setPositional(&options.registry, arg.value, "registry");
        }
    }
    if (options.registry.len == 0) return parser.missing("registry");
    return options;
}

fn rejectArgs(allocator: std.mem.Allocator, command: Command, args: []const []const u8) !void {
    var parser = ArgParser.init(allocator, command, args);
    while (try parser.next()) |arg| {
        if (arg.flag) |flag| return parser.unknownFlag(flag);
        return parser.unexpectedPositional(arg.value);
    }
}

const FlagArg = struct {
    name: []const u8,
    value: ?[]const u8,
    raw: []const u8,
};

const ParsedArg = struct {
    value: []const u8,
    flag: ?FlagArg = null,
};

const ArgParser = struct {
    allocator: std.mem.Allocator,
    command: Command,
    args: []const []const u8,
    index: usize = 0,

    fn init(allocator: std.mem.Allocator, command: Command, args: []const []const u8) ArgParser {
        return .{ .allocator = allocator, .command = command, .args = args };
    }

    fn next(self: *ArgParser) !?ParsedArg {
        if (self.index >= self.args.len) return null;
        const raw = self.args[self.index];
        self.index += 1;
        if (!std.mem.startsWith(u8, raw, "--")) return .{ .value = raw };
        if (raw.len == 2) {
            return self.fail("empty flag is not valid", .{});
        }
        const body = raw[2..];
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            const name = body[0..eq];
            const value = body[eq + 1 ..];
            if (name.len == 0 or value.len == 0) {
                return self.fail("malformed flag '{s}'", .{raw});
            }
            return .{ .value = raw, .flag = .{ .name = name, .value = value, .raw = raw } };
        }
        return .{ .value = raw, .flag = .{ .name = body, .value = null, .raw = raw } };
    }

    fn setBool(self: *ArgParser, target: *bool, flag: FlagArg) !void {
        if (flag.value != null) return self.fail("flag '--{s}' does not take a value", .{flag.name});
        if (target.*) return self.fail("duplicate flag '--{s}'", .{flag.name});
        target.* = true;
    }

    fn setValue(self: *ArgParser, target: *?[]const u8, flag: FlagArg) !void {
        if (flag.value == null) return self.fail("flag '--{s}' requires --{s}=<value>", .{ flag.name, flag.name });
        if (target.* != null) return self.fail("duplicate flag '--{s}'", .{flag.name});
        target.* = flag.value.?;
    }

    fn setPositional(self: *ArgParser, target: *[]const u8, value: []const u8, label: []const u8) !void {
        if (target.*.len != 0) return self.fail("unexpected extra positional '{s}'", .{value});
        _ = label;
        target.* = value;
    }

    fn unknownFlag(self: *ArgParser, flag: FlagArg) anyerror {
        return self.fail("unknown flag '{s}' for runa {s}", .{ flag.raw, self.command.name() });
    }

    fn unexpectedPositional(self: *ArgParser, value: []const u8) anyerror {
        return self.fail("unexpected positional '{s}' for runa {s}", .{ value, self.command.name() });
    }

    fn missing(self: *ArgParser, label: []const u8) anyerror {
        return self.fail("runa {s}: missing {s}", .{ self.command.name(), label });
    }

    fn fail(self: *ArgParser, comptime fmt: []const u8, args: anytype) anyerror {
        parse_error_message = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        return error.ParseFailure;
    }
};

fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ParseResult {
    return .{ .failure = .{ .message = try std.fmt.allocPrint(allocator, fmt, args) } };
}

threadlocal var parse_error_message: []const u8 = "";

fn parseFailureFromError(allocator: std.mem.Allocator, err: anyerror) !ParseResult {
    if (err == error.ParseFailure) {
        return .{ .failure = .{ .message = parse_error_message } };
    }
    return fail(allocator, "{s}", .{@errorName(err)});
}

fn renderCommandHelp(io: std.Io, command: Command) !void {
    const spec = commandSpec(command);
    switch (command) {
        .new => try writer.writeLines(io, .stdout, &.{ "Usage: runa new [--lib] <name>", spec.description }),
        .build => try writer.writeLines(io, .stdout, &.{ "Usage: runa build [--release] [--package=<name>] [--product=<name>|--bin=<name>|--cdylib=<name>]", spec.description }),
        .check => try writer.writeLines(io, .stdout, &.{ "Usage: runa check", spec.description }),
        .@"test" => try writer.writeLines(io, .stdout, &.{ "Usage: runa test [--parallel] [--no-capture]", spec.description }),
        .fmt => try writer.writeLines(io, .stdout, &.{ "Usage: runa fmt [--check]", spec.description }),
        .add => try writer.writeLines(io, .stdout, &.{ "Usage: runa add <name> (--version=<version>|--path=<path>) [...]", spec.description }),
        .remove => try writer.writeLines(io, .stdout, &.{ "Usage: runa remove <name>", spec.description }),
        .import => try writer.writeLines(io, .stdout, &.{ "Usage: runa import <name> --version=<version> [--registry=<name>]", spec.description }),
        .vendor => try writer.writeLines(io, .stdout, &.{ "Usage: runa vendor <name> --version=<version> [...]", spec.description }),
        .publish => try writer.writeLines(io, .stdout, &.{ "Usage: runa publish <registry> [--artifacts]", spec.description }),
        .doc, .review, .repair => try writer.writeLines(io, .stdout, &.{ "Reserved command.", "This command is recognized but unimplemented." }),
    }
}

pub const top_level_help_lines = [_][]const u8{
    "Runa stage0 CLI.",
    "Usage: runa <command> [options]",
    "",
    "Standardized commands:",
    "  new build check test fmt add remove import vendor publish",
    "Reserved later:",
    "  doc review repair",
    "",
    "Use 'runa <command> --help' for command help.",
};

test "parser accepts first wave matrix" {
    const allocator = std.testing.allocator;
    const cases = [_][]const []const u8{
        &.{},
        &.{"help"},
        &.{"-h"},
        &.{"--help"},
        &.{"version"},
        &.{"-V"},
        &.{"--version"},
        &.{ "new", "demo" },
        &.{ "new", "--lib", "demo" },
        &.{"build"},
        &.{ "build", "--release" },
        &.{ "build", "--package=demo" },
        &.{ "build", "--product=demo" },
        &.{ "build", "--bin=demo" },
        &.{ "build", "--cdylib=demo" },
        &.{"check"},
        &.{"test"},
        &.{ "test", "--parallel" },
        &.{ "test", "--no-capture" },
        &.{ "test", "--parallel", "--no-capture" },
        &.{"fmt"},
        &.{ "fmt", "--check" },
        &.{ "add", "fmt", "--version=2026.0.56" },
        &.{ "add", "fmt", "--version=2026.0.56", "--registry=default" },
        &.{ "add", "fmt", "--version=2026.0.56", "--edition=2026" },
        &.{ "add", "fmt", "--version=2026.0.56", "--lang-version=0.00" },
        &.{ "add", "fmt", "--path=vendor/fmt" },
        &.{ "remove", "fmt" },
        &.{ "import", "fmt", "--version=2026.0.56" },
        &.{ "import", "fmt", "--version=2026.0.56", "--registry=default" },
        &.{ "vendor", "fmt", "--version=2026.0.56" },
        &.{ "vendor", "fmt", "--version=2026.0.56", "--registry=default" },
        &.{ "vendor", "fmt", "--version=2026.0.56", "--edition=2026" },
        &.{ "vendor", "fmt", "--version=2026.0.56", "--lang-version=0.00" },
        &.{ "publish", "default" },
        &.{ "publish", "default", "--artifacts" },
        &.{ "doc", "--help" },
        &.{"doc"},
    };

    for (cases) |case| {
        const parsed = try parseArgs(allocator, case);
        switch (parsed) {
            .ok => {},
            .failure => |failure| std.debug.panic("{s}", .{failure.message}),
        }
    }
}

test "parser rejects hard cli misuse" {
    const allocator = std.testing.allocator;
    const cases = [_][]const []const u8{
        &.{"unknown"},
        &.{ "build", "--target=x" },
        &.{ "build", "--release", "--release" },
        &.{ "build", "--bin=a", "--cdylib=b" },
        &.{ "add", "fmt" },
        &.{ "add", "fmt", "--path=vendor/fmt", "--registry=default" },
        &.{ "test", "extra" },
        &.{ "publish", "default", "extra" },
        &.{ "vendor", "fmt", "--version" },
    };

    for (cases) |case| {
        const parsed = try parseArgs(allocator, case);
        try std.testing.expect(parsed == .failure);
        allocator.free(parsed.failure.message);
    }
}
