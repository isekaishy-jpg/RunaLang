const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const scheduler_policy_is_explicit = true;
pub const entry_adapter_is_explicit = true;
pub const detached_creation_is_explicit = true;
pub const attached_tasks_are_default = true;

pub const TaskPriority = enum {
    Critical,
    High,
    Normal,
    Low,
    Background,
};

pub const TieBreakPolicy = union(enum) {
    FirstSpawned,
    StableId,
    Explicit: usize,
};

pub const TaskSchedule = struct {
    priority: TaskPriority = .Normal,
    tie_break: TieBreakPolicy = .FirstSpawned,
};

const ChildTaskRecord = struct {
    state: *anyopaque,
    cancel_fn: *const fn (*anyopaque) void,
    teardown_fn: *const fn (*anyopaque) void,
    finished_fn: *const fn (*anyopaque) bool,
};

const StructuredTaskScope = struct {
    children: array_list.Managed(ChildTaskRecord),

    fn init(allocator: Allocator) StructuredTaskScope {
        return .{
            .children = array_list.Managed(ChildTaskRecord).init(allocator),
        };
    }

    fn deinit(self: *StructuredTaskScope) void {
        self.teardownLiveChildren();
        self.children.deinit();
    }

    fn register(self: *StructuredTaskScope, child: ChildTaskRecord) !void {
        try self.children.append(child);
    }

    fn teardownLiveChildren(self: *StructuredTaskScope) void {
        for (self.children.items) |child| {
            if (child.finished_fn(child.state)) continue;
            child.cancel_fn(child.state);
            child.teardown_fn(child.state);
        }
    }
};

fn TaskAttachmentState(comptime T: type) type {
    return struct {
        value: T,
        completed: bool = false,
        canceled: bool = false,
        teardown_complete: bool = false,
        teardown_callback: ?*const fn (?*anyopaque) void = null,
        teardown_context: ?*anyopaque = null,

        fn init(value: T) @This() {
            return .{ .value = value };
        }

        fn withTeardown(value: T, teardown_callback: *const fn (?*anyopaque) void, teardown_context: ?*anyopaque) @This() {
            return .{
                .value = value,
                .teardown_callback = teardown_callback,
                .teardown_context = teardown_context,
            };
        }
    };
}

fn attachedStatePtr(comptime T: type, raw: *anyopaque) *TaskAttachmentState(T) {
    return @ptrCast(@alignCast(raw));
}

fn runAttachedStateTeardown(comptime T: type, state: *TaskAttachmentState(T)) void {
    if (state.teardown_complete) return;
    if (state.teardown_callback) |callback| callback(state.teardown_context);
    state.teardown_complete = true;
}

fn cancelAttachedState(comptime T: type, raw: *anyopaque) void {
    const state = attachedStatePtr(T, raw);
    state.canceled = true;
    state.completed = true;
}

fn teardownAttachedState(comptime T: type, raw: *anyopaque) void {
    runAttachedStateTeardown(T, attachedStatePtr(T, raw));
}

fn attachedStateFinished(comptime T: type, raw: *anyopaque) bool {
    return attachedStatePtr(T, raw).teardown_complete;
}

fn childTaskRecord(comptime T: type, state: *TaskAttachmentState(T)) ChildTaskRecord {
    return .{
        .state = state,
        .cancel_fn = struct {
            fn call(raw: *anyopaque) void {
                cancelAttachedState(T, raw);
            }
        }.call,
        .teardown_fn = struct {
            fn call(raw: *anyopaque) void {
                teardownAttachedState(T, raw);
            }
        }.call,
        .finished_fn = struct {
            fn call(raw: *anyopaque) bool {
                return attachedStateFinished(T, raw);
            }
        }.call,
    };
}

pub fn Task(comptime T: type) type {
    return struct {
        value: T,
        completed: bool = false,
        canceled: bool = false,
        attached_state: ?*TaskAttachmentState(T) = null,

        fn syncFromAttachedState(self: *@This(), state: *TaskAttachmentState(T)) void {
            self.value = state.value;
            self.completed = state.completed;
            self.canceled = state.canceled;
        }

        pub fn complete(value: T) @This() {
            return .{
                .value = value,
                .completed = true,
                .canceled = false,
            };
        }

        fn attachForTesting(scope: *StructuredTaskScope, state: *TaskAttachmentState(T)) !@This() {
            try scope.register(childTaskRecord(T, state));
            return .{
                .value = state.value,
                .completed = state.completed,
                .canceled = state.canceled,
                .attached_state = state,
            };
        }

        pub fn cancel(self: *@This()) void {
            if (self.attached_state) |state| {
                state.canceled = true;
                state.completed = true;
                runAttachedStateTeardown(T, state);
                self.syncFromAttachedState(state);
                return;
            }
            self.canceled = true;
        }

        pub fn @"await"(self: @This()) T {
            if (self.attached_state) |state| {
                state.completed = true;
                runAttachedStateTeardown(T, state);
                return state.value;
            }
            return self.value;
        }
    };
}

fn taskResultType(callable: anytype) type {
    return switch (@typeInfo(@TypeOf(callable))) {
        .@"fn" => |fn_info| fn_info.return_type.?,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |fn_info| fn_info.return_type.?,
            else => @compileError("task helpers require a function-like callable"),
        },
        else => @compileError("task helpers require a function-like callable"),
    };
}

fn isDetachedStaticType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type, .void, .bool, .noreturn, .int, .float, .comptime_int, .comptime_float, .null, .undefined, .error_set, .@"enum", .enum_literal, .@"fn" => true,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => true,
            else => false,
        },
        .optional => |optional| isDetachedStaticType(optional.child),
        .array => |array| isDetachedStaticType(array.child),
        .vector => |vector| isDetachedStaticType(vector.child),
        .error_union => |error_union| isDetachedStaticType(error_union.payload) and isDetachedStaticType(error_union.error_set),
        .@"struct" => |struct_info| blk: {
            inline for (struct_info.fields) |field| {
                if (!isDetachedStaticType(field.type)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |union_info| blk: {
            inline for (union_info.fields) |field| {
                if (!isDetachedStaticType(field.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isSendType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type, .void, .bool, .noreturn, .int, .float, .comptime_int, .comptime_float, .null, .undefined, .error_set, .@"enum", .enum_literal, .@"fn" => true,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => true,
            else => false,
        },
        .optional => |optional| isSendType(optional.child),
        .array => |array| isSendType(array.child),
        .vector => |vector| isSendType(vector.child),
        .error_union => |error_union| isSendType(error_union.payload) and isSendType(error_union.error_set),
        .@"struct" => |struct_info| blk: {
            inline for (struct_info.fields) |field| {
                if (!isSendType(field.type)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |union_info| blk: {
            inline for (union_info.fields) |field| {
                if (!isSendType(field.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn enforceDetachedStatic(comptime T: type, comptime label: []const u8) void {
    comptime {
        if (!isDetachedStaticType(T)) {
            @compileError("detached async helper requires " ++ label ++ " to satisfy 'static");
        }
    }
}

fn enforceSend(comptime T: type, comptime label: []const u8) void {
    comptime {
        if (!isSendType(T)) {
            @compileError("worker-crossing async helper requires " ++ label ++ " to satisfy Send");
        }
    }
}

fn enforceDetachedCreation(callable: anytype, input: anytype, comptime require_send: bool) void {
    enforceDetachedStatic(@TypeOf(callable), "callable");
    enforceDetachedStatic(@TypeOf(input), "input");
    if (require_send) {
        enforceSend(@TypeOf(callable), "callable");
        enforceSend(@TypeOf(input), "input");
    }
}

pub fn block_on(callable: anytype, input: anytype) @TypeOf(callable(input)) {
    return callable(input);
}

pub fn block_on_edit(callable: anytype, input: anytype) @TypeOf(callable(input)) {
    return callable(input);
}

pub fn block_on_take(callable: anytype, input: anytype) @TypeOf(callable(input)) {
    return callable(input);
}

pub fn spawn(callable: anytype, input: anytype) Task(taskResultType(callable)) {
    return Task(taskResultType(callable)).complete(callable(input));
}

pub fn spawn_edit(callable: anytype, input: anytype) Task(taskResultType(callable)) {
    return Task(taskResultType(callable)).complete(callable(input));
}

pub fn spawn_take(callable: anytype, input: anytype) Task(taskResultType(callable)) {
    return Task(taskResultType(callable)).complete(callable(input));
}

pub fn spawn_local(callable: anytype, input: anytype) Task(taskResultType(callable)) {
    return Task(taskResultType(callable)).complete(callable(input));
}

pub fn spawn_local_edit(callable: anytype, input: anytype) Task(taskResultType(callable)) {
    return Task(taskResultType(callable)).complete(callable(input));
}

pub fn spawn_local_take(callable: anytype, input: anytype) Task(taskResultType(callable)) {
    return Task(taskResultType(callable)).complete(callable(input));
}

pub fn spawn_with(callable: anytype, input: anytype, schedule: TaskSchedule) Task(taskResultType(callable)) {
    _ = schedule;
    return spawn(callable, input);
}

pub fn spawn_with_edit(callable: anytype, input: anytype, schedule: TaskSchedule) Task(taskResultType(callable)) {
    _ = schedule;
    return spawn_edit(callable, input);
}

pub fn spawn_with_take(callable: anytype, input: anytype, schedule: TaskSchedule) Task(taskResultType(callable)) {
    _ = schedule;
    return spawn_take(callable, input);
}

pub fn spawn_local_with(callable: anytype, input: anytype, schedule: TaskSchedule) Task(taskResultType(callable)) {
    _ = schedule;
    return spawn_local(callable, input);
}

pub fn spawn_local_with_edit(callable: anytype, input: anytype, schedule: TaskSchedule) Task(taskResultType(callable)) {
    _ = schedule;
    return spawn_local_edit(callable, input);
}

pub fn spawn_local_with_take(callable: anytype, input: anytype, schedule: TaskSchedule) Task(taskResultType(callable)) {
    _ = schedule;
    return spawn_local_take(callable, input);
}

pub fn spawn_detached(callable: anytype, input: anytype) void {
    enforceDetachedCreation(callable, input, true);
    _ = callable(input);
}

pub fn spawn_detached_edit(callable: anytype, input: anytype) void {
    enforceDetachedCreation(callable, input, true);
    _ = callable(input);
}

pub fn spawn_detached_take(callable: anytype, input: anytype) void {
    enforceDetachedCreation(callable, input, true);
    _ = callable(input);
}

pub fn spawn_local_detached(callable: anytype, input: anytype) void {
    enforceDetachedCreation(callable, input, false);
    _ = callable(input);
}

pub fn spawn_local_detached_edit(callable: anytype, input: anytype) void {
    enforceDetachedCreation(callable, input, false);
    _ = callable(input);
}

pub fn spawn_local_detached_take(callable: anytype, input: anytype) void {
    enforceDetachedCreation(callable, input, false);
    _ = callable(input);
}

pub fn spawn_detached_with(callable: anytype, input: anytype, schedule: TaskSchedule) void {
    _ = schedule;
    spawn_detached(callable, input);
}

pub fn spawn_detached_with_edit(callable: anytype, input: anytype, schedule: TaskSchedule) void {
    _ = schedule;
    spawn_detached_edit(callable, input);
}

pub fn spawn_detached_with_take(callable: anytype, input: anytype, schedule: TaskSchedule) void {
    _ = schedule;
    spawn_detached_take(callable, input);
}

pub fn spawn_local_detached_with(callable: anytype, input: anytype, schedule: TaskSchedule) void {
    _ = schedule;
    spawn_local_detached(callable, input);
}

pub fn spawn_local_detached_with_edit(callable: anytype, input: anytype, schedule: TaskSchedule) void {
    _ = schedule;
    spawn_local_detached_edit(callable, input);
}

pub fn spawn_local_detached_with_take(callable: anytype, input: anytype, schedule: TaskSchedule) void {
    _ = schedule;
    spawn_local_detached_take(callable, input);
}

test "structured task teardown cancels live attached children" {
    var scope = StructuredTaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var teardown_count: usize = 0;
    const callbacks = struct {
        fn record(raw: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };

    var child_state = TaskAttachmentState(i32).withTeardown(7, callbacks.record, &teardown_count);
    _ = try Task(i32).attachForTesting(&scope, &child_state);

    scope.teardownLiveChildren();

    try std.testing.expect(child_state.canceled);
    try std.testing.expect(child_state.completed);
    try std.testing.expect(child_state.teardown_complete);
    try std.testing.expectEqual(@as(usize, 1), teardown_count);
}

test "awaited attached tasks are not torn down twice" {
    var scope = StructuredTaskScope.init(std.testing.allocator);
    defer scope.deinit();

    var teardown_count: usize = 0;
    const callbacks = struct {
        fn record(raw: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };

    var child_state = TaskAttachmentState(i32).withTeardown(11, callbacks.record, &teardown_count);
    var task = try Task(i32).attachForTesting(&scope, &child_state);

    try std.testing.expectEqual(@as(i32, 11), task.@"await"());
    try std.testing.expect(child_state.completed);
    try std.testing.expect(!child_state.canceled);
    try std.testing.expect(child_state.teardown_complete);

    scope.teardownLiveChildren();

    try std.testing.expectEqual(@as(usize, 1), teardown_count);
}

test "detached helper gates recognize static-safe and send-safe host shapes" {
    const StaticStruct = struct {
        value: i32,
        flag: bool,
    };
    const PointerStruct = struct {
        ptr: *const i32,
    };
    const callbacks = struct {
        fn addOne(value: i32) i32 {
            return value + 1;
        }
    };

    try std.testing.expect(isDetachedStaticType(i32));
    try std.testing.expect(isDetachedStaticType(StaticStruct));
    try std.testing.expect(isDetachedStaticType(@TypeOf(callbacks.addOne)));
    try std.testing.expect(!isDetachedStaticType(*const i32));
    try std.testing.expect(!isDetachedStaticType(PointerStruct));

    try std.testing.expect(isSendType(i32));
    try std.testing.expect(isSendType(StaticStruct));
    try std.testing.expect(isSendType(@TypeOf(callbacks.addOne)));
    try std.testing.expect(!isSendType(*const i32));
    try std.testing.expect(!isSendType(Task(i32)));
}
