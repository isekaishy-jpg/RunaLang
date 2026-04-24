const mir = @import("../mir/root.zig");

pub const summary = "Backend-facing summaries derived from MIR modules.";

pub const BackendSummary = struct {
    items: usize = 0,
    functions: usize = 0,
    consts: usize = 0,
};

pub fn summarize(module: *const mir.Module) BackendSummary {
    var result = BackendSummary{
        .items = module.items.items.len,
    };

    for (module.items.items) |item| {
        switch (item) {
            .function => result.functions += 1,
            .const_item => result.consts += 1,
        }
    }

    return result;
}
