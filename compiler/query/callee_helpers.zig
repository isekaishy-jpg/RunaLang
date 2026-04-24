const std = @import("std");

pub fn isSpawnHelper(callee_name: []const u8) bool {
    const known = [_][]const u8{
        "spawn",
        "spawn_edit",
        "spawn_take",
        "spawn_local",
        "spawn_local_edit",
        "spawn_local_take",
        "spawn_with",
        "spawn_with_edit",
        "spawn_with_take",
        "spawn_local_with",
        "spawn_local_with_edit",
        "spawn_local_with_take",
        "spawn_detached",
        "spawn_detached_edit",
        "spawn_detached_take",
        "spawn_local_detached",
        "spawn_local_detached_edit",
        "spawn_local_detached_take",
        "spawn_detached_with",
        "spawn_detached_with_edit",
        "spawn_detached_with_take",
        "spawn_local_detached_with",
        "spawn_local_detached_with_edit",
        "spawn_local_detached_with_take",
    };

    for (known) |known_name| {
        if (std.mem.eql(u8, callee_name, known_name)) return true;
    }
    return false;
}

pub fn isWorkerCrossingSpawnHelper(callee_name: []const u8) bool {
    const known = [_][]const u8{
        "spawn",
        "spawn_edit",
        "spawn_take",
        "spawn_with",
        "spawn_with_edit",
        "spawn_with_take",
        "spawn_detached",
        "spawn_detached_edit",
        "spawn_detached_take",
        "spawn_detached_with",
        "spawn_detached_with_edit",
        "spawn_detached_with_take",
    };

    for (known) |known_name| {
        if (std.mem.eql(u8, callee_name, known_name)) return true;
    }
    return false;
}

pub fn isDetachedSpawnHelper(callee_name: []const u8) bool {
    const known = [_][]const u8{
        "spawn_detached",
        "spawn_detached_edit",
        "spawn_detached_take",
        "spawn_local_detached",
        "spawn_local_detached_edit",
        "spawn_local_detached_take",
        "spawn_detached_with",
        "spawn_detached_with_edit",
        "spawn_detached_with_take",
        "spawn_local_detached_with",
        "spawn_local_detached_with_edit",
        "spawn_local_detached_with_take",
    };

    for (known) |known_name| {
        if (std.mem.eql(u8, callee_name, known_name)) return true;
    }
    return false;
}
