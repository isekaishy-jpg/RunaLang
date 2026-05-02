const std = @import("std");
const attribute_support = @import("../attribute_support.zig");
const query_types = @import("types.zig");
const standard_families = @import("standard_families.zig");
const session = @import("../session/root.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;
const CheckedSignatureFn = *const fn (*session.Session, session.ItemId) anyerror!query_types.CheckedSignature;

pub fn discoverPackageTests(
    allocator: Allocator,
    active: *session.Session,
    package_index: usize,
    checked_signature: CheckedSignatureFn,
) !query_types.PackageTestResult {
    var tests = std.array_list.Managed(query_types.TestDescriptor).init(allocator);
    errdefer {
        for (tests.items) |descriptor| allocator.free(descriptor.call_path);
        tests.deinit();
    }

    var package_name: []const u8 = "";
    for (active.semantic_index.items.items, 0..) |entry, item_index| {
        const module_pipeline = &active.pipeline.modules.items[entry.pipeline_module_index];
        if (module_pipeline.package_index != package_index) continue;
        if (package_name.len == 0) package_name = module_pipeline.package_name;

        const item = active.item(.{ .index = item_index });
        if (!attribute_support.hasBareAttribute(item.attributes, "test")) continue;
        const checked = try checked_signature(active, .{ .index = item_index });
        const function = switch (checked.facts) {
            .function => |function| function,
            else => continue,
        };
        if (!(try validDiscoveredTest(allocator, function))) continue;

        const call_path = if (module_pipeline.module_path.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ module_pipeline.module_path, item.name });
        errdefer allocator.free(call_path);

        const source_file = active.pipeline.sources.get(module_pipeline.typed.file_id);
        try tests.append(.{
            .item_id = .{ .index = item_index },
            .package_index = package_index,
            .package_name = package_name,
            .root_module_relative_path = source_file.path,
            .module_path = module_pipeline.module_path,
            .function_name = item.name,
            .call_path = call_path,
        });
    }

    return .{
        .package_index = package_index,
        .package_name = package_name,
        .tests = try tests.toOwnedSlice(),
    };
}

pub fn discoverAllPackageTests(
    allocator: Allocator,
    active: *session.Session,
    checked_signature: CheckedSignatureFn,
) ![]query_types.PackageTestResult {
    var results = std.array_list.Managed(query_types.PackageTestResult).init(allocator);
    errdefer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit();
    }

    var seen = std.AutoHashMap(usize, void).init(allocator);
    defer seen.deinit();
    for (active.pipeline.modules.items) |module_pipeline| {
        const entry = try seen.getOrPut(module_pipeline.package_index);
        if (entry.found_existing) continue;
        entry.value_ptr.* = {};
        try results.append(try discoverPackageTests(allocator, active, module_pipeline.package_index, checked_signature));
    }
    return results.toOwnedSlice();
}

fn validDiscoveredTest(allocator: Allocator, function: query_types.FunctionSignature) !bool {
    return !function.foreign and
        !function.is_suspend and
        function.parameters.len == 0 and
        function.generic_params.len == 0 and
        try testReturnTypeAllowed(allocator, function.return_type);
}

fn testReturnTypeAllowed(allocator: Allocator, return_type: types.TypeRef) !bool {
    if (return_type.eql(types.TypeRef.fromBuiltin(.unit))) return true;
    return standard_families.resultTypeArgsMatch(
        allocator,
        return_type,
        types.TypeRef.fromBuiltin(.unit),
        types.TypeRef.fromBuiltin(.str),
    );
}
