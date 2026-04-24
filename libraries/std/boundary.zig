pub const api_attribute = "#boundary[api]";
pub const value_attribute = "#boundary[value]";
pub const capability_attribute = "#boundary[capability]";

pub const CrossingKind = enum {
    local_only,
    transfer_safe,
    capability_safe,
};
