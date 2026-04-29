const std = @import("std");
const toolchain = @import("toolchain");

pub const Command = toolchain.cli.Command;
pub const parseSubcommand = toolchain.cli.parseSubcommand;

pub fn main(init: std.process.Init) !void {
    try toolchain.cli.main(init);
}
