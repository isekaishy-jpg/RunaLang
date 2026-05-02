const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const workspace = @import("../workspace/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Documentation extraction and rendering over the shared typed front-end.";

pub fn renderWorkspaceSummary(allocator: Allocator, loaded_workspace: *const workspace.Loaded, active: *compiler.session.Session) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("# ");
    try out.appendSlice(loaded_workspace.manifest.name.?);
    try out.appendSlice("\n\n");
    try out.appendSlice("Version: `");
    try out.appendSlice(loaded_workspace.manifest.version.?);
    try out.appendSlice("`\n");
    try out.appendSlice("Edition: `");
    try out.appendSlice(loaded_workspace.manifest.edition.?);
    try out.appendSlice("`\n");
    try out.appendSlice("Lang Version: `");
    try out.appendSlice(loaded_workspace.manifest.lang_version.?);
    try out.appendSlice("`\n\n## Products\n");

    for (loaded_workspace.products.items) |product| {
        const line = try std.fmt.allocPrint(allocator, "- `{s}` `{s}` -> `{s}`\n", .{
            @tagName(product.kind),
            product.name,
            product.root_path,
        });
        defer allocator.free(line);
        try out.appendSlice(line);
    }

    try out.appendSlice("\n## Syntax Frontend\n");
    for (active.pipeline.modules.items) |module| {
        const file = active.pipeline.sources.get(module.parsed.module.file_id);
        const line = try std.fmt.allocPrint(allocator, "- `{s}`: {d} items, {d} tokens, {d} CST nodes, {d} reused top-level nodes\n", .{
            file.path,
            module.parsed.module.itemCount(),
            module.parsed.tokens.len(),
            module.parsed.cst.nodeCount(),
            module.parsed.stats.reused_top_level_nodes,
        });
        defer allocator.free(line);
        try out.appendSlice(line);
    }

    try out.appendSlice("\n## Items\n");

    for (active.pipeline.modules.items) |module| {
        try appendParsedItems(allocator, &out, module.parsed.module);
    }

    try out.appendSlice("\n## Runtime Reflection\n");
    var found_reflection = false;
    const reflection_metadata = try compiler.query.collectRuntimeMetadata(allocator, active);
    defer allocator.free(reflection_metadata);
    for (reflection_metadata) |item| {
        found_reflection = true;
        const line = try std.fmt.allocPrint(allocator, "- `{s}` `{s}`\n", .{
            item.kind,
            item.name,
        });
        defer allocator.free(line);
        try out.appendSlice(line);
    }
    if (!found_reflection) try out.appendSlice("- none\n");

    try out.appendSlice("\n## Boundary APIs\n");
    var found_boundary = false;
    for (loaded_workspace.products.items, 0..) |product, product_index| {
        var metadata = try compiler.metadata.collectPackagedMetadataFromSession(
            allocator,
            active,
            loaded_workspace.manifest.name.?,
            loaded_workspace.manifest.version.?,
            product.name,
            @tagName(product.kind),
            product_index,
        );
        defer metadata.deinit(allocator);

        for (metadata.boundary_apis) |entry| {
            found_boundary = true;
            const line = try std.fmt.allocPrint(allocator, "- `{s}` `{s}` `{s}` -> `{s}`\n", .{
                product.name,
                entry.canonical_identity,
                entry.input_type,
                entry.output_type,
            });
            defer allocator.free(line);
            try out.appendSlice(line);
        }
    }
    if (!found_boundary) try out.appendSlice("- none\n");

    return out.toOwnedSlice();
}

fn appendParsedItems(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: compiler.ast.Module,
) !void {
    var iter = module.iterator();
    while (iter.next()) |item| {
        if (item.name.len == 0 and item.kind != .impl_block) continue;
        const line = try std.fmt.allocPrint(allocator, "- `{s}` `{s}`\n", .{
            @tagName(item.kind),
            if (item.name.len != 0) item.name else "(anonymous)",
        });
        defer allocator.free(line);
        try out.appendSlice(line);

        switch (item.body_syntax) {
            .struct_fields => |fields| {
                for (fields) |field| {
                    if (field.name == null or field.ty == null) continue;
                    const field_line = try std.fmt.allocPrint(allocator, "  - field `{s}`: `{s}`\n", .{
                        field.name.?.text,
                        field.ty.?.text(),
                    });
                    defer allocator.free(field_line);
                    try out.appendSlice(field_line);
                }
            },
            .union_fields => |fields| {
                for (fields) |field| {
                    if (field.name == null or field.ty == null) continue;
                    const field_line = try std.fmt.allocPrint(allocator, "  - union field `{s}`: `{s}`\n", .{
                        field.name.?.text,
                        field.ty.?.text(),
                    });
                    defer allocator.free(field_line);
                    try out.appendSlice(field_line);
                }
            },
            .enum_variants => |variants| {
                for (variants) |variant| {
                    const name = if (variant.name) |value| value.text else continue;
                    if (variant.tuple_payload) |tuple_payload| {
                        const payload_text = try renderTuplePayload(allocator, tuple_payload);
                        defer allocator.free(payload_text);
                        const variant_line = try std.fmt.allocPrint(allocator, "  - variant `{s}{s}`\n", .{
                            name,
                            payload_text,
                        });
                        defer allocator.free(variant_line);
                        try out.appendSlice(variant_line);
                        continue;
                    }
                    const variant_line = try std.fmt.allocPrint(allocator, "  - variant `{s}`\n", .{name});
                    defer allocator.free(variant_line);
                    try out.appendSlice(variant_line);
                    for (variant.named_fields) |field| {
                        if (field.name == null or field.ty == null) continue;
                        const field_line = try std.fmt.allocPrint(allocator, "    - field `{s}`: `{s}`\n", .{
                            field.name.?.text,
                            field.ty.?.text(),
                        });
                        defer allocator.free(field_line);
                        try out.appendSlice(field_line);
                    }
                }
            },
            .trait_body => |body| {
                for (body.associated_types) |associated_type| {
                    const name = if (associated_type.name) |value| value.text else continue;
                    const type_line = try std.fmt.allocPrint(allocator, "  - associated type `{s}`\n", .{name});
                    defer allocator.free(type_line);
                    try out.appendSlice(type_line);
                }
                for (body.methods) |method| {
                    const name = if (method.signature.name) |value| value.text else continue;
                    const method_line = try std.fmt.allocPrint(allocator, "  - {s}method `{s}`{s}\n", .{
                        if (method.is_suspend) "suspend " else "",
                        name,
                        if (method.block_syntax != null) " with default body" else "",
                    });
                    defer allocator.free(method_line);
                    try out.appendSlice(method_line);
                }
            },
            .impl_body => |body| {
                switch (item.syntax) {
                    .impl_block => |signature| {
                        const header_line = if (signature.trait_name) |trait_name|
                            try std.fmt.allocPrint(allocator, "  - impl `{s}` for `{s}`\n", .{
                                trait_name.text(),
                                if (signature.target_type) |target_type| target_type.text() else "",
                            })
                        else
                            try std.fmt.allocPrint(allocator, "  - inherent impl for `{s}`\n", .{
                                if (signature.target_type) |target_type| target_type.text() else "",
                            });
                        defer allocator.free(header_line);
                        try out.appendSlice(header_line);
                    },
                    else => {},
                }
                for (body.methods) |method| {
                    const name = if (method.signature.name) |value| value.text else continue;
                    const method_line = try std.fmt.allocPrint(allocator, "    - {s}method `{s}`{s}\n", .{
                        if (method.is_suspend) "suspend " else "",
                        name,
                        if (method.block_syntax != null) " with body" else "",
                    });
                    defer allocator.free(method_line);
                    try out.appendSlice(method_line);
                }
            },
            .none => {},
        }
    }
}

fn renderTuplePayload(allocator: Allocator, payload: compiler.ast.TuplePayloadSyntax) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.append('(');
    for (payload.types, 0..) |field_type, index| {
        if (index != 0) try out.appendSlice(", ");
        try out.appendSlice(field_type.text());
    }
    try out.append(')');
    return out.toOwnedSlice();
}
