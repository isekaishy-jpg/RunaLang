pub const api_attribute = "#boundary[api]";
pub const value_attribute = "#boundary[value]";
pub const capability_attribute = "#boundary[capability]";
pub const binding_is_explicit = true;
pub const ambient_auto_registration = false;
pub const wildcard_endpoint_discovery = false;
pub const runtime_invoke_by_name = false;
pub const erased_universal_call_object = false;

pub const CrossingKind = enum {
    local_only,
    transfer_safe,
    capability_safe,
};

pub const TransportFamily = enum {
    direct_api,
    message,
    host_plugin,
};

pub const InvocationShape = enum {
    typed_stub,
    typed_adapter,
};

pub const FailureSurface = enum {
    none,
    explicit_transport_failure,
};

pub const TransportContract = struct {
    family: TransportFamily,
    invocation_shape: InvocationShape,
    failure_surface: FailureSurface,
    preserves_boundary_contract: bool = true,
};

pub const direct_api_transport = TransportContract{
    .family = .direct_api,
    .invocation_shape = .typed_stub,
    .failure_surface = .none,
};

pub const message_transport = TransportContract{
    .family = .message,
    .invocation_shape = .typed_adapter,
    .failure_surface = .explicit_transport_failure,
};

pub const host_plugin_transport = TransportContract{
    .family = .host_plugin,
    .invocation_shape = .typed_adapter,
    .failure_surface = .explicit_transport_failure,
};
