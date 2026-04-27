const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const summary = "Dynamic-library leaf hooks for explicit runtime loading.";

pub const type_name = "DynamicLibrary";
pub const open_name = "open_library";
pub const lookup_name = "lookup_symbol";
pub const close_name = "close_library";

pub const open_callee = "__runa_dynamic_open_library";
pub const lookup_callee = "__runa_dynamic_lookup_symbol";
pub const close_callee = "__runa_dynamic_close_library";

pub const open_result_type_name = "Result[DynamicLibrary, DynamicLibraryError]";
pub const close_result_type_name = "Result[Unit, DynamicLibraryError]";
pub const lookup_error_type_name = "SymbolLookupError";

pub fn isTypeName(raw: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), type_name);
}

pub fn isPublicCallee(raw: []const u8) bool {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    return std.mem.eql(u8, name, open_name) or
        std.mem.eql(u8, name, lookup_name) or
        std.mem.eql(u8, name, close_name);
}

pub fn isLeafCallee(raw: []const u8) bool {
    return std.mem.eql(u8, raw, open_callee) or
        std.mem.eql(u8, raw, lookup_callee) or
        std.mem.eql(u8, raw, close_callee);
}

pub fn renderSupport(allocator: Allocator) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("#if defined(_WIN32)\n");
    try out.appendSlice("#include <windows.h>\n\n");
    try out.appendSlice("static void* __runa_dynamic_open_library(const char* path) {\n");
    try out.appendSlice("    HMODULE handle = LoadLibraryA(path);\n");
    try out.appendSlice("    if (handle == NULL) runa_abort();\n");
    try out.appendSlice("    return (void*)handle;\n");
    try out.appendSlice("}\n\n");
    try out.appendSlice("static void* __runa_dynamic_lookup_symbol(void* library, const char* name) {\n");
    try out.appendSlice("    FARPROC symbol = GetProcAddress((HMODULE)library, name);\n");
    try out.appendSlice("    if (symbol == NULL) runa_abort();\n");
    try out.appendSlice("    return (void*)symbol;\n");
    try out.appendSlice("}\n\n");
    try out.appendSlice("static void __runa_dynamic_close_library(void* library) {\n");
    try out.appendSlice("    if (!FreeLibrary((HMODULE)library)) runa_abort();\n");
    try out.appendSlice("}\n\n");
    try out.appendSlice("#else\n");
    try out.appendSlice("#error dynamic-library runtime hooks are unsupported for this stage0 target\n");
    try out.appendSlice("#endif\n\n");
    return out.toOwnedSlice();
}
