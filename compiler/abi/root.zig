const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");

pub const summary = "ABI validation over typed foreign declarations.";
pub const c = @import("c/root.zig");
pub const c_abi_required = true;

pub fn validateForeignFunction(
    span: source.Span,
    has_body: bool,
    is_unsafe: bool,
    function: *const typed.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    if (!function.foreign) return;
    try c.validateImportedFunction(span, has_body, is_unsafe, function, diagnostics);
}
