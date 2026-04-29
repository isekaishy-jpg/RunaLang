const compiler = @import("compiler");

pub const summary = "Query-backed #test discovery and execution boundary.";
pub const discovery_attribute = "#test";
pub const product_name_heuristics_are_removed = true;

pub const TestDescriptor = compiler.query.TestDescriptor;
pub const PackageTestResult = compiler.query.PackageTestResult;
