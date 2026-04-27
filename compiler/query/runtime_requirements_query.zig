const std = @import("std");
const backend_contract = @import("../backend_contract/root.zig");
const session = @import("../session/root.zig");
const target = @import("../target/root.zig");

const array_list = std.array_list;

pub fn build(active: *session.Session, key: backend_contract.RuntimeRequirementKey) !backend_contract.RuntimeRequirementResult {
    const supported = runtimeLeafSupported(key.target_name);
    const has_entry = key.output_kind == .bin and moduleHasEntry(active, key.module_id);
    const needs_async = moduleNeedsAsyncHooks(active, key.module_id);

    var requirements = array_list.Managed(backend_contract.RuntimeRequirementDescriptor).init(active.allocator);
    defer requirements.deinit();
    var unsupported = array_list.Managed(backend_contract.UnsupportedLowering).init(active.allocator);
    defer unsupported.deinit();
    errdefer deinitUnsupportedItems(active.allocator, unsupported.items);

    try appendRequirement(active.allocator, &requirements, &unsupported, .entry_adapter, has_entry, supported, "runtime.entry_adapter.unsupported", "entry adapter runtime hook is unsupported for target");
    try appendRequirement(active.allocator, &requirements, &unsupported, .fatal_abort, true, supported, "runtime.fatal_abort.unsupported", "fatal abort runtime hook is unsupported for target");
    try appendRequirement(active.allocator, &requirements, &unsupported, .async_hooks, needs_async, false, "runtime.async_hooks.unsupported", "async runtime hooks are unsupported in stage0");
    try appendRequirement(active.allocator, &requirements, &unsupported, .dynamic_library_hooks, false, false, "runtime.dynamic_library_hooks.unsupported", "dynamic-library runtime hooks are unsupported in stage0");
    try appendRequirement(active.allocator, &requirements, &unsupported, .observability_hooks, false, false, "runtime.observability_hooks.unsupported", "observability hooks are library-owned and not compiler-runtime-owned");

    var result_key = try backend_contract.cloneRuntimeRequirementKey(active.allocator, key);
    errdefer backend_contract.deinitRuntimeRequirementKey(active.allocator, &result_key);
    const requirement_slice = try requirements.toOwnedSlice();
    errdefer if (requirement_slice.len != 0) active.allocator.free(requirement_slice);
    const unsupported_slice = try unsupported.toOwnedSlice();
    errdefer deinitUnsupported(active.allocator, unsupported_slice);

    return .{
        .key = result_key,
        .requirements = requirement_slice,
        .unsupported = unsupported_slice,
    };
}

fn appendRequirement(
    allocator: std.mem.Allocator,
    requirements: *array_list.Managed(backend_contract.RuntimeRequirementDescriptor),
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
    kind: backend_contract.RuntimeRequirementKind,
    required: bool,
    supported: bool,
    unsupported_code: []const u8,
    unsupported_message: []const u8,
) !void {
    try requirements.append(.{
        .kind = kind,
        .required = required,
        .supported = supported,
    });
    if (required and !supported) {
        try appendUnsupported(allocator, unsupported, unsupported_code, unsupported_message);
    }
}

fn moduleHasEntry(active: *const session.Session, module_id: session.ModuleId) bool {
    for (active.semantic_index.items.items, 0..) |item_entry, item_index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = item_index });
        if (std.mem.eql(u8, item.name, "main")) return true;
    }
    return false;
}

fn moduleNeedsAsyncHooks(active: *const session.Session, module_id: session.ModuleId) bool {
    for (active.semantic_index.items.items, 0..) |item_entry, item_index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = item_index });
        if (item.kind == .suspend_function) return true;
    }
    return false;
}

fn runtimeLeafSupported(target_name: []const u8) bool {
    if (std.mem.eql(u8, target_name, target.windows.name)) return true;
    if (std.mem.eql(u8, target_name, target.linux.name)) return false;
    return false;
}

fn appendUnsupported(
    allocator: std.mem.Allocator,
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
    code: []const u8,
    message: []const u8,
) !void {
    const owned_code = try allocator.dupe(u8, code);
    errdefer allocator.free(owned_code);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try unsupported.append(.{
        .code = owned_code,
        .message = owned_message,
    });
}

fn deinitUnsupported(allocator: std.mem.Allocator, unsupported: []const backend_contract.UnsupportedLowering) void {
    deinitUnsupportedItems(allocator, unsupported);
    if (unsupported.len != 0) allocator.free(unsupported);
}

fn deinitUnsupportedItems(allocator: std.mem.Allocator, unsupported: []const backend_contract.UnsupportedLowering) void {
    for (unsupported) |item| {
        if (item.code.len != 0) allocator.free(item.code);
        if (item.message.len != 0) allocator.free(item.message);
    }
}
