pub const windows = @import("windows/root.zig");
pub const linux = @import("linux/root.zig");
const builtin = @import("builtin");

pub const Descriptor = struct {
    name: []const u8,
    supported_stage0: bool,
    executable_extension: []const u8,
    dynamic_library_extension: []const u8,
    shared_library_prefix: []const u8,
};

pub const supported_targets = [_][]const u8{
    windows.name,
    linux.name,
};

pub fn host() Descriptor {
    return switch (builtin.os.tag) {
        .windows => .{
            .name = windows.name,
            .supported_stage0 = windows.supported_stage0,
            .executable_extension = windows.executable_extension,
            .dynamic_library_extension = windows.dynamic_library_extension,
            .shared_library_prefix = windows.shared_library_prefix,
        },
        .linux => .{
            .name = linux.name,
            .supported_stage0 = linux.supported_stage0,
            .executable_extension = linux.executable_extension,
            .dynamic_library_extension = linux.dynamic_library_extension,
            .shared_library_prefix = linux.shared_library_prefix,
        },
        else => .{
            .name = @tagName(builtin.os.tag),
            .supported_stage0 = false,
            .executable_extension = "",
            .dynamic_library_extension = "",
            .shared_library_prefix = "",
        },
    };
}

pub fn hostName() []const u8 {
    return host().name;
}

pub fn hostExecutableExtension() []const u8 {
    return host().executable_extension;
}

pub fn hostDynamicLibraryExtension() []const u8 {
    return host().dynamic_library_extension;
}

pub fn hostStage0Supported() bool {
    return host().supported_stage0;
}

pub fn stage0WindowsHostSupported() bool {
    return builtin.os.tag == .windows and hostStage0Supported();
}
