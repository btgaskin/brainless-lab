const DEFAULT_CAMERA_WAVELENGTHS_NM = Tuple(350.0:10.0:750.0)

"""One mounted scalar-field channel with an independent response state."""
struct MountedFieldProbe{S<:SensorResponseState} <: AbstractSensor
    channel::Symbol
    mount::Mount2D
    response::SensorResponse
    state::S
end

rawspec(probe::MountedFieldProbe) = (
    kind=:field_probe,
    width=1,
    channel=probe.channel,
    mount=probe.mount,
)

function portspec(probe::MountedFieldProbe)
    receptors = Port{Mount2D}[Port(Symbol(:field_, probe.channel), probe.mount)]
    return PortSpec(1, 0, receptors, Port{NoPlacement}[])
end

n_receptors(::MountedFieldProbe) = 1
n_effectors(::MountedFieldProbe) = 0
ports(probe::MountedFieldProbe) = ports(portspec(probe))

function sample_field_probe!(
    probe::MountedFieldProbe,
    field::AbstractSpatialField,
    position,
    heading::Real,
    tick::Integer,
    arena::Union{Torus,WalledArena},
)
    pose_ = mounted_pose(position, heading, probe.mount, arena)
    raw = _checked_field_value(field, pose_.position, tick, arena)
    return only(respond!(probe.state, probe.response, (raw,)))
end

function sample!(probe::MountedFieldProbe, args...)
    sample_field_probe!(probe, args...)
    return probe.state.output
end

function encode!(probe::MountedFieldProbe, samples)
    length(samples) == 1 || throw(DimensionMismatch(
        "field probe :$(probe.channel) expected one sample, got $(length(samples))",
    ))
    value = Float64(only(samples))
    isfinite(value) || throw(ArgumentError("field probe :$(probe.channel) sample must be finite"))
    return samples isa Vector{Float64} ? samples : Float64[value]
end

component_state(probe::MountedFieldProbe) = (response=copy(probe.state.values),)

reset!(probe::MountedFieldProbe) = (reset!(probe.state); probe)

_sensor_component_config(sensor::MountedFieldProbe) = (
    kind=:field_probe,
    channel=sensor.channel,
    mount=_mount_config(sensor.mount),
    response=_sensor_response_config(sensor.response),
    initial=Tuple(sensor.state.initial),
    shared_seed=sensor.state.shared_seed,
    independent_seed=sensor.state.independent_seed,
)

"""Bilateral contrast with explicit stable references to its source components."""
struct BilateralContrastEncoder <: AbstractBilateralEncoder
    left::Symbol
    right::Symbol
    encoder::UnitContrastEncoder
end

encoder_sources(encoder::BilateralContrastEncoder) = (encoder.left, encoder.right)
encode_bilateral(encoder::BilateralContrastEncoder, samples) =
    encode_bilateral(encoder.encoder, samples)
encode!(encoder::BilateralContrastEncoder, samples) = encode_bilateral(encoder, samples)

_encoder_component_config(encoder::BilateralContrastEncoder) = (
    kind=:bilateral_contrast,
    left=encoder.left,
    right=encoder.right,
    epsilon=encoder.encoder.epsilon,
)

function portspec(camera::SpectralCamera)
    P = NamedTuple{(:mount, :ray_angle),Tuple{Mount2D,Float64}}
    receptors = Vector{Port{P}}(undef, n_camera_channels(camera) * n_camera_rays(camera))
    index = 1
    for channel in camera.channels, (ray, angle) in enumerate(camera.ray_angles)
        placement = (mount=camera.mount, ray_angle=angle)
        receptors[index] = Port(Symbol(channel, :_ray_, ray), placement)
        index += 1
    end
    return PortSpec(length(receptors), 0, receptors, Port{NoPlacement}[])
end

n_receptors(camera::SpectralCamera) = n_camera_channels(camera) * n_camera_rays(camera)
n_effectors(::SpectralCamera) = 0
ports(camera::SpectralCamera) = ports(portspec(camera))

sample!(camera::SpectralCamera, args...) = sample_spectral_camera(camera, args...)

function encode!(camera::SpectralCamera, sample)
    values = sample isa NamedTuple && hasproperty(sample, :values) ? sample.values : sample
    length(values) == n_receptors(camera) || throw(DimensionMismatch(
        "spectral camera expected $(n_receptors(camera)) channel-major samples, got $(length(values))",
    ))
    encoded = values isa Vector{Float64} ? values : Float64.(vec(collect(values)))
    all(isfinite, encoded) || throw(ArgumentError("spectral camera samples must be finite"))
    return encoded
end

component_state(::SpectralCamera) = NamedTuple()

_sensor_component_config(sensor::SectorVision) = (
    kind=:sector_vision,
    source=_sensory_source_config(sensor.source),
    channels=sensor.channels,
    field_of_view_deg=rad2deg(sensor.field_of_view),
    range=sensor.max_range,
    gain=sensor.gain,
    distance_exponent=sensor.distance_exponent,
    mode=sensor.mode,
    sham_seed=sensor.sham_seed,
)

function _component_parameter_error(config::ComponentConfig, message::AbstractString)
    throw(ArgumentError(
        "component :$(config.id) (:$(config.family)/:$(config.kind)) $(message)",
    ))
end

function _component_parameters(
    config::ComponentConfig;
    allowed::Tuple,
    required::Tuple=(),
)
    names = propertynames(config.parameters)
    unknown = sort!(collect(setdiff(Set(names), Set(allowed))); by=String)
    isempty(unknown) || _component_parameter_error(
        config,
        "has unknown parameter(s) $(unknown); allowed: $(collect(allowed))",
    )
    missing = Symbol[name for name in required if !hasproperty(config.parameters, name)]
    isempty(missing) || _component_parameter_error(
        config,
        "is missing required parameter(s) $(missing)",
    )
    return config.parameters
end

_parameter(parameters::NamedTuple, name::Symbol, default) =
    hasproperty(parameters, name) ? getproperty(parameters, name) : default

function _real_parameter(config::ComponentConfig, parameters, name::Symbol, default=nothing)
    value = _parameter(parameters, name, default)
    value === nothing && _component_parameter_error(config, "requires parameter :$(name)")
    value isa Real && !(value isa Bool) || _component_parameter_error(
        config,
        "parameter :$(name) must be a real number, got $(repr(value))",
    )
    value_ = Float64(value)
    isfinite(value_) || _component_parameter_error(config, "parameter :$(name) must be finite")
    return value_
end

function _integer_parameter(config::ComponentConfig, parameters, name::Symbol, default=nothing)
    value = _parameter(parameters, name, default)
    value === nothing && _component_parameter_error(config, "requires parameter :$(name)")
    value isa Integer && !(value isa Bool) || _component_parameter_error(
        config,
        "parameter :$(name) must be an integer, got $(repr(value))",
    )
    return Int(value)
end

function _bool_parameter(config::ComponentConfig, parameters, name::Symbol, default=nothing)
    value = _parameter(parameters, name, default)
    value === nothing && _component_parameter_error(config, "requires parameter :$(name)")
    value isa Bool || _component_parameter_error(
        config,
        "parameter :$(name) must be true or false, got $(repr(value))",
    )
    return value
end

function _symbol_parameter(config::ComponentConfig, parameters, name::Symbol, default=nothing)
    value = _parameter(parameters, name, default)
    value === nothing && _component_parameter_error(config, "requires parameter :$(name)")
    value isa Union{Symbol,AbstractString} || _component_parameter_error(
        config,
        "parameter :$(name) must be a string, got $(repr(value))",
    )
    isempty(strip(String(value))) && _component_parameter_error(config, "parameter :$(name) must not be empty")
    return Symbol(value)
end

function _tuple_parameter(config::ComponentConfig, parameters, name::Symbol; length_=nothing)
    value = _parameter(parameters, name, nothing)
    value isa Tuple || _component_parameter_error(
        config,
        "parameter :$(name) must be a TOML array, got $(repr(value))",
    )
    length_ === nothing || length(value) == length_ || _component_parameter_error(
        config,
        "parameter :$(name) must contain $(length_) values, got $(length(value))",
    )
    return value
end

function _real_tuple(config::ComponentConfig, parameters, name::Symbol; length_=nothing)
    values = _tuple_parameter(config, parameters, name; length_=length_)
    return Tuple(
        begin
            value isa Real && !(value isa Bool) || _component_parameter_error(
                config,
                "parameter :$(name) must contain only real numbers",
            )
            value_ = Float64(value)
            isfinite(value_) || _component_parameter_error(
                config,
                "parameter :$(name) must contain only finite numbers",
            )
            value_
        end
        for value in values
    )
end

function _symbol_tuple(config::ComponentConfig, parameters, name::Symbol)
    values = _tuple_parameter(config, parameters, name)
    isempty(values) && _component_parameter_error(config, "parameter :$(name) must not be empty")
    symbols = Tuple(
        value isa Union{Symbol,AbstractString} ? Symbol(value) :
        _component_parameter_error(config, "parameter :$(name) must contain only strings")
        for value in values
    )
    length(unique(symbols)) == length(symbols) || _component_parameter_error(
        config,
        "parameter :$(name) must contain unique values",
    )
    return symbols
end

function _mount_parameter(config::ComponentConfig, parameters)
    mount = hasproperty(parameters, :mount) ?
        _real_tuple(config, parameters, :mount; length_=2) :
        (0.0, 0.0)
    yaw_deg = _real_parameter(config, parameters, :yaw_deg, 0.0)
    return Mount2D(mount, deg2rad(yaw_deg))
end

function _resolve_disc(config::ComponentConfig)
    parameters = _component_parameters(config; allowed=(:radius,), required=(:radius,))
    return DiscGeometry(_real_parameter(config, parameters, :radius))
end

function _regulated_entry_error(config::ComponentConfig, index::Integer, message::AbstractString)
    _component_parameter_error(config, "regulated variable $(Int(index)) $(message)")
end

function _regulated_entry_value(config, entry, index, name::Symbol, default=nothing)
    entry isa NamedTuple || _regulated_entry_error(config, index, "must be a TOML table")
    return hasproperty(entry, name) ? getproperty(entry, name) : default
end

function _regulated_entry_symbol(config, entry, index, name::Symbol, default=nothing)
    value = _regulated_entry_value(config, entry, index, name, default)
    value === nothing && _regulated_entry_error(config, index, "requires parameter :$(name)")
    value isa Union{Symbol,AbstractString} || _regulated_entry_error(
        config, index, "parameter :$(name) must be a string",
    )
    isempty(strip(String(value))) && _regulated_entry_error(
        config, index, "parameter :$(name) must not be empty",
    )
    return Symbol(value)
end

function _regulated_entry_real(config, entry, index, name::Symbol, default=nothing)
    value = _regulated_entry_value(config, entry, index, name, default)
    value === nothing && _regulated_entry_error(config, index, "requires parameter :$(name)")
    value isa Real && !(value isa Bool) || _regulated_entry_error(
        config, index, "parameter :$(name) must be a real number",
    )
    value_ = Float64(value)
    isfinite(value_) || _regulated_entry_error(config, index, "parameter :$(name) must be finite")
    return value_
end

function _regulated_entry_bool(config, entry, index, name::Symbol, default=nothing)
    value = _regulated_entry_value(config, entry, index, name, default)
    value === nothing && _regulated_entry_error(config, index, "requires parameter :$(name)")
    value isa Bool || _regulated_entry_error(
        config, index, "parameter :$(name) must be true or false",
    )
    return value
end

function _regulated_deficit(config, entry, index)
    kind = _regulated_entry_symbol(config, entry, index, :deficit, :below)
    kind === :below && return BelowSetpoint()
    kind === :above && return AboveSetpoint()
    kind in (:distance, :setpoint_distance) && return SetpointDistance()
    _regulated_entry_error(config, index, ":deficit must be below, above, or distance")
end

function _regulated_curve(config, entry, index)
    kind = _regulated_entry_symbol(config, entry, index, :curve, :linear)
    kind === :linear && return LinearResponse()
    kind === :constant && return ConstantResponse(
        _regulated_entry_real(config, entry, index, :curve_value, 1.0),
    )
    kind === :power && return PowerResponse(
        _regulated_entry_real(config, entry, index, :curve_exponent, 1.0),
    )
    kind === :logistic && return LogisticResponse(
        _regulated_entry_real(config, entry, index, :curve_slope, 10.0),
        _regulated_entry_real(config, entry, index, :curve_midpoint, 0.5),
    )
    kind === :threshold && return ThresholdResponse(
        _regulated_entry_real(config, entry, index, :curve_threshold, 0.5),
    )
    _regulated_entry_error(config, index, ":curve must be linear, constant, power, logistic, or threshold")
end

function _regulated_mode(config, entry, index)
    kind = _regulated_entry_symbol(config, entry, index, :feedback_mode, :off)
    kind === :off && return OffFeedback()
    kind === :tonic && return TonicFeedback()
    kind in (:bernoulli, :spikes) && return BernoulliFeedback()
    if kind === :replay
        values = _regulated_entry_value(config, entry, index, :feedback_values, nothing)
        values isa Tuple || _regulated_entry_error(
            config, index, ":feedback_values must be a TOML array for replay feedback",
        )
        all(value -> value isa Real && !(value isa Bool), values) || _regulated_entry_error(
            config, index, ":feedback_values must contain only real numbers",
        )
        return ReplayFeedback(
            Float64.(collect(values));
            cycle=_regulated_entry_bool(config, entry, index, :feedback_cycle, true),
        )
    end
    _regulated_entry_error(config, index, ":feedback_mode must be off, tonic, bernoulli, or replay")
end

function _regulated_failure(config, entry, index)
    kind = _regulated_entry_symbol(config, entry, index, :failure, :none)
    kind === :none && return NoFailure()
    threshold = _regulated_entry_real(config, entry, index, :failure_threshold)
    kind === :below && return BelowFailure(threshold)
    kind === :above && return AboveFailure(threshold)
    _regulated_entry_error(config, index, ":failure must be none, below, or above")
end

const _REGULATED_VARIABLE_PARAMETERS = Set((
    :name, :minimum, :maximum, :initial, :setpoint, :drift, :deficit,
    :curve, :curve_value, :curve_exponent, :curve_slope, :curve_midpoint,
    :curve_threshold, :feedback_mode, :feedback_values, :feedback_cycle,
    :gain, :emission_p, :link_p, :failure, :failure_threshold,
))

function _resolve_regulated_variable(config::ComponentConfig, entry, index::Integer)
    entry isa NamedTuple || _regulated_entry_error(config, index, "must be a TOML table")
    unknown = sort!(collect(setdiff(Set(propertynames(entry)), _REGULATED_VARIABLE_PARAMETERS)); by=String)
    isempty(unknown) || _regulated_entry_error(config, index, "has unknown parameter(s) $(unknown)")
    name = _regulated_entry_symbol(config, entry, index, :name)
    minimum = _regulated_entry_real(config, entry, index, :minimum, 0.0)
    maximum = _regulated_entry_real(config, entry, index, :maximum, 1.0)
    initial = _regulated_entry_real(config, entry, index, :initial, maximum)
    setpoint = _regulated_entry_real(config, entry, index, :setpoint, maximum)
    raw_link = _regulated_entry_value(config, entry, index, :link_p, nothing)
    link_p = raw_link === nothing ? nothing : _regulated_entry_real(config, entry, index, :link_p)
    return RegulatedVariable(
        name;
        minimum=minimum,
        maximum=maximum,
        initial=initial,
        setpoint=setpoint,
        drift=_regulated_entry_real(config, entry, index, :drift, 0.0),
        deficit=_regulated_deficit(config, entry, index),
        curve=_regulated_curve(config, entry, index),
        mode=_regulated_mode(config, entry, index),
        gain=_regulated_entry_real(config, entry, index, :gain, 1.0),
        emission_p=_regulated_entry_real(config, entry, index, :emission_p, 1.0),
        link_p=link_p,
        failure=_regulated_failure(config, entry, index),
    )
end

function _resolve_regulated_physiology(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:variables, :seed, :unknown_effects),
        required=(:variables,),
    )
    entries = _tuple_parameter(config, parameters, :variables)
    isempty(entries) && _component_parameter_error(config, ":variables must contain at least one regulated variable")
    variables = Tuple(
        _resolve_regulated_variable(config, entry, index)
        for (index, entry) in enumerate(entries)
    )
    policy = _symbol_parameter(config, parameters, :unknown_effects, :reject)
    unknown_effects = if policy === :reject
        RejectUnknownEffects()
    elseif policy === :ignore
        IgnoreUnknownEffects()
    else
        _component_parameter_error(config, ":unknown_effects must be reject or ignore")
    end
    return RegulatedPhysiology(
        variables;
        seed=_integer_parameter(config, parameters, :seed, 0),
        unknown_effects=unknown_effects,
    )
end

function _resolve_no_physiology(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:unknown_effects,),
    )
    policy = _symbol_parameter(config, parameters, :unknown_effects, :reject)
    unknown_effects = if policy === :reject
        RejectUnknownEffects()
    elseif policy === :ignore
        IgnoreUnknownEffects()
    else
        _component_parameter_error(config, ":unknown_effects must be reject or ignore")
    end
    return NoPhysiology(; unknown_effects)
end

function _resolve_identity_encoder(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:ports, :sources),
        required=(:ports,),
    )
    port_ids = _symbol_tuple(config, parameters, :ports)
    source_ids = hasproperty(parameters, :sources) ?
        _symbol_tuple(config, parameters, :sources) :
        ()
    return IdentityEncoder(port_ids; sources=source_ids)
end

function _resolve_mean_readout(config::ComponentConfig)
    _component_parameters(config; allowed=())
    return MeanReadout()
end

function _resolve_instant_readout(config::ComponentConfig)
    _component_parameters(config; allowed=())
    return InstantReadout()
end

function _resolve_voting_readout(config::ComponentConfig)
    _component_parameters(config; allowed=())
    return VotingReadout()
end


const _CAMERA_CHANNEL_CENTRES_NM = Dict(
    :ultraviolet => 365.0,
    :uv => 365.0,
    :blue => 460.0,
    :green => 540.0,
    :red => 610.0,
)

function _default_camera_sensitivity(config::ComponentConfig, channels, grid::SpectralGrid)
    matrix = Matrix{Float64}(undef, length(channels), length(grid))
    for (row, channel) in enumerate(channels)
        centre = get(_CAMERA_CHANNEL_CENTRES_NM, channel, nothing)
        centre === nothing && _component_parameter_error(
            config,
            "channel :$(channel) needs explicit :sensitivity; built-in defaults exist for uv/ultraviolet, blue, green, and red",
        )
        width = channel in (:uv, :ultraviolet) ? 25.0 : 45.0
        @inbounds for column in eachindex(grid.wavelengths_nm)
            offset = (grid.wavelengths_nm[column] - centre) / width
            matrix[row, column] = exp(-0.5 * offset * offset)
        end
    end
    return matrix
end

function _camera_sensitivity(config::ComponentConfig, parameters, channels, grid::SpectralGrid)
    hasproperty(parameters, :sensitivity) || return _default_camera_sensitivity(config, channels, grid)
    rows = _tuple_parameter(config, parameters, :sensitivity; length_=length(channels))
    matrix = Matrix{Float64}(undef, length(channels), length(grid))
    for (row, values) in enumerate(rows)
        values isa Tuple || _component_parameter_error(
            config,
            "parameter :sensitivity must be an array of channel arrays",
        )
        length(values) == length(grid) || _component_parameter_error(
            config,
            "sensitivity row $(row) has $(length(values)) values; expected $(length(grid))",
        )
        for (column, value) in enumerate(values)
            value isa Real && !(value isa Bool) || _component_parameter_error(
                config,
                "parameter :sensitivity must contain only real numbers",
            )
            value_ = Float64(value)
            isfinite(value_) || _component_parameter_error(config, "parameter :sensitivity must be finite")
            matrix[row, column] = value_
        end
    end
    return matrix
end

function _camera_ray_angles(config::ComponentConfig, parameters)
    rays = _integer_parameter(config, parameters, :rays)
    rays >= 1 || _component_parameter_error(config, "parameter :rays must be at least one")
    field_of_view = _real_parameter(config, parameters, :field_of_view_deg)
    0.0 < field_of_view <= 360.0 || _component_parameter_error(
        config,
        "parameter :field_of_view_deg must lie in (0, 360]",
    )
    rays == 1 && return (0.0,)
    half = deg2rad(field_of_view) / 2.0
    return Tuple(range(-half, half; length=rays))
end

function _resolve_spectral_camera(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(
            :channels, :field_of_view_deg, :rays, :range, :wavelengths_nm,
            :sensitivity, :mount, :yaw_deg, :exposure, :saturation,
        ),
        required=(:channels, :field_of_view_deg, :rays, :range),
    )
    channels = _symbol_tuple(config, parameters, :channels)
    wavelengths = hasproperty(parameters, :wavelengths_nm) ?
        _real_tuple(config, parameters, :wavelengths_nm) :
        DEFAULT_CAMERA_WAVELENGTHS_NM
    grid = SpectralGrid(wavelengths)
    sensitivity = _camera_sensitivity(config, parameters, channels, grid)
    max_range = _real_parameter(config, parameters, :range)
    max_range > 0.0 || _component_parameter_error(config, "parameter :range must be positive")
    exposure = _real_parameter(config, parameters, :exposure, 1.0)
    exposure >= 0.0 || _component_parameter_error(config, "parameter :exposure must be non-negative")
    saturation = _real_parameter(config, parameters, :saturation, floatmax(Float64))
    saturation > 0.0 || _component_parameter_error(config, "parameter :saturation must be positive")
    return SpectralCamera(
        grid,
        channels,
        sensitivity;
        ray_angles=_camera_ray_angles(config, parameters),
        mount=_mount_parameter(config, parameters),
        max_range=max_range,
        exposure=exposure,
        saturation=saturation,
    )
end

function _resolve_sector_vision(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(
            :source,
            :channels,
            :field_of_view_deg,
            :range,
            :gain,
            :distance_exponent,
            :mode,
            :sham_seed,
        ),
        required=(:source, :range),
    )
    source_name_ = _symbol_parameter(config, parameters, :source)
    source = source_name_ === :conspecific ? ConspecificSource() : ObjectSource(source_name_)
    channels = _integer_parameter(config, parameters, :channels, 16)
    channels >= 1 || _component_parameter_error(config, "parameter :channels must be positive")
    fov = _real_parameter(config, parameters, :field_of_view_deg, 300.0)
    0.0 < fov <= 360.0 || _component_parameter_error(
        config,
        "parameter :field_of_view_deg must lie in (0, 360]",
    )
    range = _real_parameter(config, parameters, :range)
    range > 0.0 || _component_parameter_error(config, "parameter :range must be positive")
    mode = _symbol_parameter(config, parameters, :mode, :veridical)
    mode in (:veridical, :blind, :bearing_sham) || _component_parameter_error(
        config,
        "parameter :mode must be veridical, blind, or bearing_sham",
    )
    return SectorVision(
        source;
        channels,
        field_of_view=deg2rad(fov),
        max_range=range,
        gain=_real_parameter(config, parameters, :gain, 1.0),
        distance_exponent=_real_parameter(config, parameters, :distance_exponent, 1.0),
        mode,
        sham_seed=_integer_parameter(config, parameters, :sham_seed, 0),
    )
end

function _catalog_component_seed(id::Symbol, stream::Symbol)
    value = UInt64(0xcbf29ce484222325)
    for byte in codeunits(string(id, ':', stream))
        value = xor(value, UInt64(byte)) * UInt64(0x00000100000001b3)
    end
    return Int(mod(value, UInt64(typemax(Int))))
end

function _resolve_field_probe(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(
            :channel, :mount, :yaw_deg, :response_tau, :dt, :shared_sigma,
            :independent_sigma, :minimum, :maximum, :initial, :shared_seed,
            :independent_seed,
        ),
        required=(:channel, :mount),
    )
    response = SensorResponse(
        tau=_real_parameter(config, parameters, :response_tau, 0.0),
        dt=_real_parameter(config, parameters, :dt, 1.0),
        shared_sigma=_real_parameter(config, parameters, :shared_sigma, 0.0),
        independent_sigma=_real_parameter(config, parameters, :independent_sigma, 0.0),
        minimum=_real_parameter(config, parameters, :minimum, 0.0),
        maximum=_real_parameter(config, parameters, :maximum, 1.0),
    )
    shared_seed = _integer_parameter(config, parameters, :shared_seed, 0)
    independent_seed = _integer_parameter(
        config,
        parameters,
        :independent_seed,
        _catalog_component_seed(config.id, :independent_noise),
    )
    state = SensorResponseState(
        1;
        initial=_real_parameter(config, parameters, :initial, 0.0),
        shared_seed=shared_seed,
        independent_seed=independent_seed,
    )
    return MountedFieldProbe(
        _symbol_parameter(config, parameters, :channel),
        _mount_parameter(config, parameters),
        response,
        state,
    )
end

function _resolve_bilateral_contrast(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:left, :right, :epsilon),
        required=(:left, :right),
    )
    left = _symbol_parameter(config, parameters, :left)
    right = _symbol_parameter(config, parameters, :right)
    left === right && _component_parameter_error(config, ":left and :right must reference different components")
    epsilon = _real_parameter(config, parameters, :epsilon, sqrt(eps(Float64)))
    return BilateralContrastEncoder(left, right, UnitContrastEncoder(epsilon))
end

function _resolve_forward_turn(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:max_forward, :max_turn, :allow_reverse),
        required=(:max_forward, :max_turn),
    )
    return ForwardTurnActuator(
        _real_parameter(config, parameters, :max_forward),
        _real_parameter(config, parameters, :max_turn);
        allow_reverse=_bool_parameter(config, parameters, :allow_reverse, false),
    )
end

function _resolve_antagonistic_turn(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:max_forward, :max_turn),
        required=(:max_forward, :max_turn),
    )
    return AntagonisticTurnActuator(
        _real_parameter(config, parameters, :max_forward),
        _real_parameter(config, parameters, :max_turn),
    )
end

function _resolve_differential_actuator(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:max_speed, :allow_reverse),
        required=(:max_speed,),
    )
    return DifferentialDriveActuator(
        _real_parameter(config, parameters, :max_speed);
        allow_reverse=_bool_parameter(config, parameters, :allow_reverse, false),
    )
end

function _resolve_planar_force_yaw(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:max_force, :max_yaw),
        required=(:max_force, :max_yaw),
    )
    return PlanarForceYawActuator(
        _real_parameter(config, parameters, :max_force),
        _real_parameter(config, parameters, :max_yaw),
    )
end

function _resolve_unicycle_dynamics(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:dt, :linear_tau, :angular_tau),
    )
    return UnicycleDynamics(
        _real_parameter(config, parameters, :dt, 1.0),
        _real_parameter(config, parameters, :linear_tau, 0.0),
        _real_parameter(config, parameters, :angular_tau, 0.0),
    )
end

function _resolve_differential_dynamics(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(:dt, :wheel_base),
        required=(:wheel_base,),
    )
    return DifferentialDriveDynamics(
        _real_parameter(config, parameters, :dt, 1.0),
        _real_parameter(config, parameters, :wheel_base),
    )
end

function _resolve_planar_rigid_body(config::ComponentConfig)
    parameters = _component_parameters(
        config;
        allowed=(
            :dt, :mass, :moment_of_inertia, :linear_drag, :angular_drag,
            :max_linear_speed, :max_angular_speed,
        ),
    )
    return PlanarRigidBodyDynamics(
        _real_parameter(config, parameters, :dt, 1.0),
        _real_parameter(config, parameters, :mass, 1.0),
        _real_parameter(config, parameters, :moment_of_inertia, 1.0),
        _real_parameter(config, parameters, :linear_drag, 0.0),
        _real_parameter(config, parameters, :angular_drag, 0.0),
        _real_parameter(config, parameters, :max_linear_speed, 10.0),
        _real_parameter(config, parameters, :max_angular_speed, 2pi),
    )
end

function _builtin_component_descriptor(
    family::Symbol,
    kind::Symbol,
    resolver;
    capabilities,
    parameters=(required=(), optional=()),
    conformance::Symbol,
    conformance_path::AbstractString,
    example_path::AbstractString,
    readiness::Symbol=:integrated,
    docs_path::AbstractString="site/src/content/docs/contracts.mdx",
    core_tests=(),
)
    return ComponentDescriptor(
        family,
        kind,
        resolver;
        readiness,
        capabilities=capabilities,
        parameters=parameters,
        conformance=conformance,
        conformance_path=conformance_path,
        docs_path,
        example_path=example_path,
        core_tests,
    )
end

function _register_builtin_component_catalog!()
    core_docs = "site/src/content/docs/core/embodiment.mdx"
    robot_example = "examples/embodiments/differential_robot.toml"
    robot_tests = (:core_differential_robot_roundtrip, :core_object_world_runtime)
    descriptors = (
        _builtin_component_descriptor(
            :geometry, :disc, _resolve_disc;
            capabilities=(:config_materialization, :collision_geometry),
            parameters=(required=(:radius,), optional=()),
            conformance=:disc_geometry_contract,
            conformance_path="test/test_physical_components.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=robot_tests,
        ),
        _builtin_component_descriptor(
            :physiology, :none, _resolve_no_physiology;
            capabilities=(:config_materialization, :explicit_no_physiology),
            parameters=(required=(), optional=(:unknown_effects,)),
            conformance=:no_physiology_contract,
            conformance_path="test/test_core_platform.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=(:core_differential_robot_roundtrip, :core_no_physiology_default),
        ),
        _builtin_component_descriptor(
            :physiology, :regulated, _resolve_regulated_physiology;
            capabilities=(:config_materialization, :multiple_needs, :feedback, :mortality, :exposures),
            parameters=(required=(:variables,), optional=(:seed, :unknown_effects)),
            conformance=:regulated_physiology_contract,
            conformance_path="test/test_component_catalog.jl",
            example_path="examples/embodiments/bilateral_insect.toml",
        ),
        _builtin_component_descriptor(
            :sensor, :spectral_camera, _resolve_spectral_camera;
            capabilities=(:config_materialization, :spectral_vision, :occlusion, :channel_major),
            parameters=(
                required=(:channels, :field_of_view_deg, :rays, :range),
                optional=(:wavelengths_nm, :sensitivity, :mount, :yaw_deg, :exposure, :saturation),
            ),
            conformance=:spectral_camera_contract,
            conformance_path="test/test_spectral_vision.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=robot_tests,
        ),
        _builtin_component_descriptor(
            :sensor, :sector_vision, _resolve_sector_vision;
            capabilities=(
                :config_materialization,
                :egocentric_sector_vision,
                :object_sources,
                :conspecific_sources,
                :input_gain,
                :distance_response_curve,
                :matched_blind_control,
                :bearing_sham_control,
            ),
            parameters=(
                required=(:source, :range),
                optional=(
                    :channels,
                    :field_of_view_deg,
                    :gain,
                    :distance_exponent,
                    :mode,
                    :sham_seed,
                ),
            ),
            conformance=:sector_vision_contract,
            conformance_path="test/test_shoal_forage.jl",
            example_path="experiments/shoal_vision_sweep/protocol.toml",
            docs_path="site/src/content/docs/experimental/embodiment.mdx",
        ),
        _builtin_component_descriptor(
            :sensor, :field_probe, _resolve_field_probe;
            capabilities=(:config_materialization, :mounted_field_sampling, :response_state),
            parameters=(
                required=(:channel, :mount),
                optional=(
                    :yaw_deg, :response_tau, :dt, :shared_sigma, :independent_sigma,
                    :minimum, :maximum, :initial, :shared_seed, :independent_seed,
                ),
            ),
            conformance=:field_probe_contract,
            conformance_path="test/test_component_catalog.jl",
            example_path="examples/embodiments/bilateral_insect.toml",
        ),
        _builtin_component_descriptor(
            :encoder, :bilateral_contrast, _resolve_bilateral_contrast;
            capabilities=(:config_materialization, :bilateral_encoding),
            parameters=(required=(:left, :right), optional=(:epsilon,)),
            conformance=:bilateral_contrast_contract,
            conformance_path="test/test_bilateral_sensing.jl",
            example_path="examples/embodiments/bilateral_insect.toml",
        ),
        _builtin_component_descriptor(
            :encoder, :identity, _resolve_identity_encoder;
            capabilities=(:config_materialization, :identity_encoding, :stable_sensor_sources),
            parameters=(required=(:ports,), optional=(:sources,)),
            conformance=:identity_encoder_contract,
            conformance_path="test/test_core_platform.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=(:core_differential_robot_roundtrip, :core_identity_encoder_composition),
        ),
        _builtin_component_descriptor(
            :readout, :mean, _resolve_mean_readout;
            capabilities=(:config_materialization, :temporal_reduction, :graded_output),
            parameters=(required=(), optional=()),
            conformance=:mean_readout_contract,
            conformance_path="test/test_interaction_cycle.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=(:core_differential_robot_roundtrip,),
        ),
        _builtin_component_descriptor(
            :readout, :instant, _resolve_instant_readout;
            capabilities=(:config_materialization, :temporal_reduction, :final_frame_output),
            parameters=(required=(), optional=()),
            conformance=:instant_readout_contract,
            conformance_path="test/test_interaction_cycle.jl",
            example_path="test/test_interaction_cycle.jl",
        ),
        _builtin_component_descriptor(
            :readout, :voting, _resolve_voting_readout;
            capabilities=(:config_materialization, :temporal_reduction, :categorical_output),
            parameters=(required=(), optional=()),
            conformance=:voting_readout_contract,
            conformance_path="test/test_interaction_cycle.jl",
            example_path="test/test_interaction_cycle.jl",
        ),
        _builtin_component_descriptor(
            :actuator, :forward_turn, _resolve_forward_turn;
            capabilities=(:config_materialization, :effector_decode),
            parameters=(required=(:max_forward, :max_turn), optional=(:allow_reverse,)),
            conformance=:forward_turn_actuator_contract,
            conformance_path="test/test_physical_components.jl",
            example_path="examples/embodiments/bilateral_insect.toml",
        ),
        _builtin_component_descriptor(
            :actuator, :antagonistic_turn, _resolve_antagonistic_turn;
            capabilities=(:config_materialization, :effector_decode, :variable_speed),
            parameters=(required=(:max_forward, :max_turn), optional=()),
            conformance=:antagonistic_turn_actuator_contract,
            conformance_path="test/test_shoal_forage.jl",
            example_path="experiments/shoal_vision_sweep/protocol.toml",
            docs_path="site/src/content/docs/experimental/embodiment.mdx",
        ),
        _builtin_component_descriptor(
            :actuator, :differential_drive, _resolve_differential_actuator;
            capabilities=(:config_materialization, :effector_decode),
            parameters=(required=(:max_speed,), optional=(:allow_reverse,)),
            conformance=:differential_drive_actuator_contract,
            conformance_path="test/test_physical_components.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=robot_tests,
        ),
        _builtin_component_descriptor(
            :actuator, :planar_force_yaw, _resolve_planar_force_yaw;
            capabilities=(:config_materialization, :effector_decode),
            parameters=(required=(:max_force, :max_yaw), optional=()),
            conformance=:planar_force_yaw_actuator_contract,
            conformance_path="test/test_physical_components.jl",
            example_path="examples/embodiments/planar_uav.toml",
        ),
        _builtin_component_descriptor(
            :dynamics, :unicycle, _resolve_unicycle_dynamics;
            capabilities=(:config_materialization, :motion_integration),
            parameters=(required=(), optional=(:dt, :linear_tau, :angular_tau)),
            conformance=:unicycle_dynamics_contract,
            conformance_path="test/test_physical_components.jl",
            example_path="examples/embodiments/bilateral_insect.toml",
        ),
        _builtin_component_descriptor(
            :dynamics, :differential_drive, _resolve_differential_dynamics;
            capabilities=(:config_materialization, :motion_integration),
            parameters=(required=(:wheel_base,), optional=(:dt,)),
            conformance=:differential_drive_dynamics_contract,
            conformance_path="test/test_physical_components.jl",
            example_path=robot_example,
            readiness=:core,
            docs_path=core_docs,
            core_tests=robot_tests,
        ),
        _builtin_component_descriptor(
            :dynamics, :planar_rigid_body, _resolve_planar_rigid_body;
            capabilities=(:config_materialization, :motion_integration),
            parameters=(
                required=(),
                optional=(
                    :dt, :mass, :moment_of_inertia, :linear_drag, :angular_drag,
                    :max_linear_speed, :max_angular_speed,
                ),
            ),
            conformance=:planar_rigid_body_dynamics_contract,
            conformance_path="test/test_physical_components.jl",
            example_path="examples/embodiments/planar_uav.toml",
        ),
    )
    foreach(register_component!, descriptors)
    return descriptors
end

const BUILTIN_COMPONENT_DESCRIPTORS = _register_builtin_component_catalog!()
