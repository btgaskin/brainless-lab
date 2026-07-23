abstract type SensorySource end

"""Select active situated objects whose declared perceptual channel matches `name`."""
struct ObjectSource{Name} <: SensorySource end
ObjectSource(name::Symbol) = ObjectSource{name}()
ObjectSource(name::AbstractString) = ObjectSource(Symbol(name))

"""Select a named analytic field from a situated environment."""
struct SpatialFieldSource{Name} <: SensorySource end
SpatialFieldSource(name::Symbol) = SpatialFieldSource{name}()
SpatialFieldSource(name::AbstractString) = SpatialFieldSource(Symbol(name))

"""Select other active embodied entities in the same physical world."""
struct ConspecificSource <: SensorySource end

source_name(::ObjectSource{Name}) where {Name} = Name
source_name(::SpatialFieldSource{Name}) where {Name} = Name

abstract type SensoryModality end

"""Ray-based bearing vision of circular object sources."""
struct BearingModality{S<:AbstractSensor,C} <: SensoryModality
    sensor::S
    range::Union{Nothing,Float64}
    curve::C
end

function BearingModality(;
    sensor::AbstractSensor=BEARING_DEFAULT,
    range=nothing,
    curve=LinearResponse(),
)
    range_ = _sensory_range(range)
    return BearingModality{typeof(sensor),typeof(curve)}(sensor, range_, curve)
end

"""Local scalar-field probes placed evenly in the body frame."""
struct FieldModality{C} <: SensoryModality
    range::Union{Nothing,Float64}
    curve::C
    probe_count::Int
    probe_radius::Float64
    aggregation::Symbol
end

function FieldModality(;
    range=nothing,
    curve=LinearResponse(),
    probe_count::Integer=8,
    probe_radius::Real=0.5,
    aggregation::Symbol=:max,
)
    range_ = _sensory_range(range)
    count_ = Int(probe_count)
    radius_ = Float64(probe_radius)
    count_ >= 1 || throw(ArgumentError("field probe_count must be at least one"))
    isfinite(radius_) && radius_ >= 0.0 ||
        throw(ArgumentError("field probe_radius must be finite and non-negative"))
    aggregation in (:max, :sum) ||
        throw(ArgumentError("field aggregation must be :max or :sum"))
    return FieldModality{typeof(curve)}(range_, curve, count_, radius_, aggregation)
end

"""Disable a modality while retaining its exact receptor layout."""
struct OffModality{M<:SensoryModality} <: SensoryModality
    modality::M
end
OffModality() = OffModality(FieldModality())

function _sensory_range(range)
    range === nothing && return nothing
    value = Float64(range)
    isfinite(value) && value > 0.0 ||
        throw(ArgumentError("sensory range must be finite and positive"))
    return value
end

_active_modality(modality::SensoryModality) = modality
_active_modality(modality::OffModality) = _active_modality(modality.modality)
_modality_curve(modality::Union{BearingModality,FieldModality}) = modality.curve
_modality_curve(modality::OffModality) = _modality_curve(modality.modality)
_modality_range(modality::Union{BearingModality,FieldModality}) = modality.range
_modality_range(modality::OffModality) = _modality_range(modality.modality)
_raw_bank_width(modality::BearingModality) = n_sensors(modality.sensor)
_raw_bank_width(modality::FieldModality) = modality.probe_count
_raw_bank_width(modality::OffModality) = _raw_bank_width(modality.modality)
_encoded_bank_width(modality::BearingModality) = 2 + n_sensors(modality.sensor)
_encoded_bank_width(modality::FieldModality) = modality.probe_count
_encoded_bank_width(modality::OffModality) = _encoded_bank_width(modality.modality)

"""Source, modality, encoding, gain, and reservoir wiring for one sensor bank."""
struct SensorBank{S<:SensorySource,M<:SensoryModality}
    name::Symbol
    source::S
    modality::M
    norm_mode::Union{Nothing,Symbol}
    norm_sigma::Float64
    gain::Float64
    link_p::Union{Nothing,Float64}
end

function SensorBank(
    name::Symbol;
    source::SensorySource=ObjectSource(name),
    modality=nothing,
    sensor=nothing,
    range=nothing,
    curve=LinearResponse(),
    norm_mode=nothing,
    norm_sigma::Real=1.0,
    gain::Real=1.0,
    link_p=nothing,
)
    sigma = Float64(norm_sigma)
    gain_ = Float64(gain)
    isfinite(sigma) && sigma > 0.0 ||
        throw(ArgumentError("sensor-bank norm_sigma must be finite and positive"))
    isfinite(gain_) && gain_ >= 0.0 ||
        throw(ArgumentError("sensor-bank gain must be finite and non-negative"))
    link_p_ = link_p === nothing ? nothing : Float64(link_p)
    link_p_ === nothing || 0.0 <= link_p_ <= 1.0 ||
        throw(ArgumentError("sensor-bank link_p must lie in [0, 1]"))
    modality_ = if modality === nothing
        BearingModality(
            sensor=sensor === nothing ? BEARING_DEFAULT : sensor,
            range=range,
            curve=curve,
        )
    else
        sensor === nothing || throw(ArgumentError(
            "pass sensor through BearingModality when modality is explicit",
        ))
        range === nothing || throw(ArgumentError(
            "pass range through the explicit sensory modality",
        ))
        modality isa SensoryModality ||
            throw(ArgumentError("modality must be a SensoryModality"))
        modality
    end
    return SensorBank{typeof(source),typeof(modality_)}(
        name,
        source,
        modality_,
        norm_mode === nothing ? nothing : Symbol(norm_mode),
        sigma,
        gain_,
        link_p_,
    )
end

SensorBank(name::AbstractString; kwargs...) = SensorBank(Symbol(name); kwargs...)
bank_width(bank::SensorBank) = _encoded_bank_width(bank.modality)
raw_bank_width(bank::SensorBank) = _raw_bank_width(bank.modality)
rawspec(bank::SensorBank) = (id=bank.name, width=raw_bank_width(bank), source=bank.source)

"""Identity sensor component for task worlds that already emit receptor vectors."""
struct DirectRelaySensor <: AbstractSensor
    port_ids::Tuple{Vararg{Symbol}}
end

function DirectRelaySensor(width::Integer)
    width_ = Int(width)
    width_ >= 0 || throw(ArgumentError("direct sensor width must be non-negative"))
    return DirectRelaySensor(ntuple(i -> Symbol(:direct_, i), width_))
end

n_sensors(sensor::DirectRelaySensor) = length(sensor.port_ids)
rawspec(sensor::DirectRelaySensor) = (id=:direct, width=n_sensors(sensor))
function portspec(sensor::DirectRelaySensor)
    receptors = Port{NoPlacement}[Port(id) for id in sensor.port_ids]
    return PortSpec(length(receptors), 0, receptors, Port{NoPlacement}[])
end
function encode!(sensor::DirectRelaySensor, percept)
    values = _component_float_vector(percept)
    length(values) == n_sensors(sensor) || throw(DimensionMismatch(
        "direct sensor expected $(n_sensors(sensor)) values, got $(length(values))",
    ))
    return values
end

"""
    SituatedSensorLayout(; ...)

Temporary generic sensor component preserving the current situated bearing,
source, signalling, colour, and additional-bank receptor contract. It is an
ordinary sensor component and can be replaced bank-by-bank without changing the
`Embodiment` type.
"""
struct SituatedSensorLayout{S<:AbstractSensor,B<:Tuple} <: AbstractSensor
    sensory_scaling::Bool
    source_bank::Bool
    source_gain::Float64
    signalling::Bool
    norm_mode::Union{Nothing,Symbol}
    norm_sigma::Float64
    conspecific_gain::Float64
    n_colours::Int
    colour_sensing::Bool
    sensor::S
    sensory_banks::B
end

function SituatedSensorLayout(;
    sensory_scaling::Bool=true,
    source_bank::Bool=false,
    source_gain::Real=1.0,
    signalling::Bool=false,
    norm_mode=nothing,
    norm_sigma::Real=1.0,
    conspecific_gain::Real=1.0,
    n_colours::Integer=1,
    colour_sensing::Bool=false,
    sensor::AbstractSensor=BEARING_DEFAULT,
    sensory_banks=(),
)
    banks = Tuple(sensory_banks)
    all(bank -> bank isa SensorBank, banks) ||
        throw(ArgumentError("situated sensor banks must all be SensorBank values"))
    sigma = Float64(norm_sigma)
    source_gain_ = Float64(source_gain)
    conspecific_gain_ = Float64(conspecific_gain)
    isfinite(sigma) && sigma > 0.0 ||
        throw(ArgumentError("situated norm_sigma must be finite and positive"))
    isfinite(source_gain_) && source_gain_ >= 0.0 ||
        throw(ArgumentError("source_gain must be finite and non-negative"))
    isfinite(conspecific_gain_) && conspecific_gain_ >= 0.0 ||
        throw(ArgumentError("conspecific_gain must be finite and non-negative"))
    Int(n_colours) >= 1 || throw(ArgumentError("n_colours must be at least one"))
    return SituatedSensorLayout{typeof(sensor),typeof(banks)}(
        sensory_scaling,
        source_bank,
        source_gain_,
        signalling,
        norm_mode === nothing ? nothing : Symbol(norm_mode),
        sigma,
        conspecific_gain_,
        Int(n_colours),
        colour_sensing,
        sensor,
        banks,
    )
end

n_sensors(layout::SituatedSensorLayout) = _situated_receptor_count(layout)
rawspec(layout::SituatedSensorLayout) = (
    id=:situated,
    width=n_sensors(layout),
    banks=Tuple(rawspec(bank) for bank in layout.sensory_banks),
)

const _SITUATED_RECEPTOR_PLACEMENT = Union{NoPlacement,Float64}

_conspecific_width(colour_sensing::Bool, n_colours::Integer; n_sensors::Integer=DEFAULT_BEARING_SENSOR_COUNT) =
    colour_sensing ? (2 + Int(n_colours) * Int(n_sensors)) : (2 + Int(n_sensors))

_signal_receptor_index(colour_sensing::Bool, n_colours::Integer; n_sensors::Integer=DEFAULT_BEARING_SENSOR_COUNT) =
    _conspecific_width(colour_sensing, n_colours; n_sensors=n_sensors) + 1

function _situated_receptor_count(layout::SituatedSensorLayout)
    nb = n_sensors(layout.sensor)
    conspecific = _conspecific_width(layout.colour_sensing, layout.n_colours; n_sensors=nb)
    source = layout.source_bank ? 2 + nb : 0
    return conspecific + source + sum(bank_width, layout.sensory_banks; init=0)
end

function _base_receptor_ports(layout::SituatedSensorLayout)
    nb = n_sensors(layout.sensor)
    degrees = angles_deg(layout.sensor)
    width = _conspecific_width(layout.colour_sensing, layout.n_colours; n_sensors=nb)
    out = Vector{Port{_SITUATED_RECEPTOR_PLACEMENT}}(undef, width)
    out[1] = Port{_SITUATED_RECEPTOR_PLACEMENT}(:reserved_1, NO_PLACEMENT)
    out[2] = Port{_SITUATED_RECEPTOR_PLACEMENT}(:reserved_2, NO_PLACEMENT)
    if layout.colour_sensing
        @inbounds for colour in 0:(layout.n_colours - 1), i in 1:nb
            out[2 + colour * nb + i] = Port{_SITUATED_RECEPTOR_PLACEMENT}(
                Symbol("conspecific_c", colour, "_bearing_", i),
                Float64(degrees[i]),
            )
        end
    else
        @inbounds for i in 1:nb
            out[2 + i] = Port{_SITUATED_RECEPTOR_PLACEMENT}(Symbol("bearing_", i), Float64(degrees[i]))
        end
    end
    return out
end

_probe_angles_deg(count::Integer) = Float64[360.0 * (i - 1) / Int(count) for i in 1:Int(count)]

function _append_bank_ports!(out, offset::Int, bank::SensorBank, modality::BearingModality)
    degrees = angles_deg(modality.sensor)
    out[offset + 1] = Port{_SITUATED_RECEPTOR_PLACEMENT}(Symbol(bank.name, :_reserved_1), NO_PLACEMENT)
    out[offset + 2] = Port{_SITUATED_RECEPTOR_PLACEMENT}(Symbol(bank.name, :_reserved_2), NO_PLACEMENT)
    @inbounds for i in eachindex(degrees)
        out[offset + 2 + i] = Port{_SITUATED_RECEPTOR_PLACEMENT}(
            Symbol(bank.name, :_bearing_, i),
            Float64(degrees[i]),
        )
    end
    return offset + bank_width(bank)
end

function _append_bank_ports!(out, offset::Int, bank::SensorBank, modality::FieldModality)
    degrees = _probe_angles_deg(modality.probe_count)
    @inbounds for i in eachindex(degrees)
        out[offset + i] = Port{_SITUATED_RECEPTOR_PLACEMENT}(
            Symbol(bank.name, :_probe_, i),
            degrees[i],
        )
    end
    return offset + bank_width(bank)
end

_append_bank_ports!(out, offset::Int, bank::SensorBank, modality::OffModality) =
    _append_bank_ports!(out, offset, bank, _active_modality(modality))

function portspec(layout::SituatedSensorLayout)
    base = _base_receptor_ports(layout)
    nb = n_sensors(layout.sensor)
    degrees = angles_deg(layout.sensor)
    width = n_sensors(layout)
    out = Vector{Port{_SITUATED_RECEPTOR_PLACEMENT}}(undef, width)
    copyto!(out, base)
    offset = length(base)
    if layout.source_bank
        out[offset + 1] = Port{_SITUATED_RECEPTOR_PLACEMENT}(
            layout.signalling ? :acoustic : :source_reserved_1,
            NO_PLACEMENT,
        )
        out[offset + 2] = Port{_SITUATED_RECEPTOR_PLACEMENT}(:source_reserved_2, NO_PLACEMENT)
        @inbounds for i in 1:nb
            out[offset + 2 + i] = Port{_SITUATED_RECEPTOR_PLACEMENT}(
                Symbol("source_bearing_", i),
                Float64(degrees[i]),
            )
        end
        offset += 2 + nb
    end
    for bank in layout.sensory_banks
        offset = _append_bank_ports!(out, offset, bank, bank.modality)
    end
    return PortSpec(width, 0, out, Port{NoPlacement}[])
end

function _curve_bank!(values::Vector{Float64}, curve)
    @inbounds for i in eachindex(values)
        values[i] = response_value(curve, clamp(values[i], 0.0, 1.0))
    end
    return values
end

function _encode_sensor_bank(bank::SensorBank, raw, modality::BearingModality)
    values = _component_float_vector(raw)
    length(values) == n_sensors(modality.sensor) || throw(DimensionMismatch(
        "sensor bank :$(bank.name) expected $(n_sensors(modality.sensor)) bearing samples, got $(length(values))",
    ))
    _curve_bank!(values, modality.curve)
    return assemble_inputs(
        values,
        false;
        norm_mode=bank.norm_mode,
        norm_sigma=bank.norm_sigma,
        gain=bank.gain,
        n_sensors=n_sensors(modality.sensor),
    )
end

function _encode_sensor_bank(bank::SensorBank, raw, modality::FieldModality)
    values = _component_float_vector(raw)
    length(values) == modality.probe_count || throw(DimensionMismatch(
        "sensor bank :$(bank.name) expected $(modality.probe_count) field samples, got $(length(values))",
    ))
    _curve_bank!(values, modality.curve)
    _normalize_bank!(values, something(bank.norm_mode, :raw), bank.norm_sigma)
    bank.gain == 1.0 || (values .*= bank.gain)
    return values
end

function _encode_sensor_bank(bank::SensorBank, raw, modality::OffModality)
    length(_component_float_vector(raw)) == raw_bank_width(bank) || throw(DimensionMismatch(
        "disabled sensor bank :$(bank.name) received the wrong sample width",
    ))
    return zeros(Float64, bank_width(bank))
end

_encode_sensor_bank(bank::SensorBank, raw) = _encode_sensor_bank(bank, raw, bank.modality)

function _encode_situated(layout::SituatedSensorLayout, percept::NamedTuple)
    hasproperty(percept, :conspecific) ||
        throw(ArgumentError("situated percept requires a :conspecific bank"))
    nb = n_sensors(layout.sensor)
    base = if layout.source_bank
        hasproperty(percept, :source) ||
            throw(ArgumentError("source-seeking percept requires a :source bank"))
        source_gain = hasproperty(percept, :source_gain) ? percept.source_gain : layout.source_gain
        values = assemble_forage_inputs(
            percept.conspecific,
            percept.source,
            layout.sensory_scaling;
            source_gain=source_gain,
            norm_mode=layout.norm_mode,
            norm_sigma=layout.norm_sigma,
            conspecific_gain=layout.conspecific_gain,
            n_colours=layout.n_colours,
            colour_sensing=layout.colour_sensing,
            n_sensors=nb,
        )
        if layout.signalling && hasproperty(percept, :acoustic)
            values[_signal_receptor_index(layout.colour_sensing, layout.n_colours; n_sensors=nb)] =
                Float64(percept.acoustic)
        end
        values
    else
        assemble_inputs(
            percept.conspecific,
            layout.sensory_scaling;
            norm_mode=layout.norm_mode,
            norm_sigma=layout.norm_sigma,
            gain=layout.conspecific_gain,
            n_colours=layout.n_colours,
            colour_sensing=layout.colour_sensing,
            n_sensors=nb,
        )
    end
    isempty(layout.sensory_banks) && return base
    bank_percept = hasproperty(percept, :sensory) ? percept.sensory : percept.objects
    output = Vector{Float64}(undef, n_sensors(layout))
    copyto!(output, 1, base, 1, length(base))
    offset = length(base)
    for bank in layout.sensory_banks
        hasproperty(bank_percept, bank.name) ||
            throw(ArgumentError("sensory percept is missing bank :$(bank.name)"))
        encoded = _encode_sensor_bank(bank, getproperty(bank_percept, bank.name))
        copyto!(output, offset + 1, encoded, 1, length(encoded))
        offset += length(encoded)
    end
    return output
end

function _encode_situated(layout::SituatedSensorLayout, percept)
    values = _component_float_vector(percept)
    length(values) == n_sensors(layout) && return values
    nb = n_sensors(layout.sensor)
    conspecific_width = layout.colour_sensing ? layout.n_colours * nb : nb
    if layout.source_bank && length(values) == conspecific_width + nb
        return assemble_forage_inputs(
            @view(values[1:conspecific_width]),
            @view(values[(conspecific_width + 1):(conspecific_width + nb)]),
            layout.sensory_scaling;
            source_gain=layout.source_gain,
            norm_mode=layout.norm_mode,
            norm_sigma=layout.norm_sigma,
            conspecific_gain=layout.conspecific_gain,
            n_colours=layout.n_colours,
            colour_sensing=layout.colour_sensing,
            n_sensors=nb,
        )
    elseif !layout.source_bank && length(values) == conspecific_width
        return assemble_inputs(
            values,
            layout.sensory_scaling;
            norm_mode=layout.norm_mode,
            norm_sigma=layout.norm_sigma,
            gain=layout.conspecific_gain,
            n_colours=layout.n_colours,
            colour_sensing=layout.colour_sensing,
            n_sensors=nb,
        )
    end
    throw(DimensionMismatch("situated percept has incompatible width $(length(values))"))
end

"""Encoder for the temporary situated sensor layout's receptor representation."""
struct SituatedEncoder{L<:SituatedSensorLayout} <: AbstractEncoder
    layout::L
end

portspec(encoder::SituatedEncoder) = portspec(encoder.layout)
encode!(encoder::SituatedEncoder, percept) = _encode_situated(encoder.layout, percept)

"""Legacy situated actuator as an ordinary component during dynamics migration."""
struct SituatedActuator <: AbstractActuator
    policy::KinematicMotor
    signalling::Bool
end
SituatedActuator(policy::KinematicMotor=KinematicMotor(); signalling::Bool=false) =
    SituatedActuator(policy, signalling)

function portspec(actuator::SituatedActuator)
    ports_ = Port{NoPlacement}[Port(:turn_left), Port(:turn_right), Port(:forward)]
    actuator.signalling && push!(ports_, Port(:signal))
    return PortSpec(0, length(ports_), Port{NoPlacement}[], ports_)
end
readout_policy(actuator::SituatedActuator) = actuator.policy
decode!(actuator::SituatedActuator, values) = _bounded_situated_effectors(values)
command_buffer(actuator::SituatedActuator) = DirectCommand(n_effectors(actuator))
function decode!(command::DirectCommand, actuator::SituatedActuator, values)
    bounded = _bounded_situated_effectors(values)
    length(command.values) == length(bounded) || throw(DimensionMismatch(
        "situated command buffer has width $(length(command.values)); expected $(length(bounded))",
    ))
    copyto!(command.values, bounded)
    return command
end

readout_policy(::AbstractActuator) = PASSTHROUGH_MOTOR
function decode!(actuator::DirectRelayActuator, values)
    command = command_buffer(actuator)
    decode!(command, actuator, values)
    return command.values
end

abstract type UnknownEffectPolicy end
struct RejectUnknownEffects <: UnknownEffectPolicy end
struct IgnoreUnknownEffects <: UnknownEffectPolicy end

_handle_unknown_effect(::IgnoreUnknownEffects, effect) = nothing
_handle_unknown_effect(::RejectUnknownEffects, effect) = throw(ArgumentError(
    "no embodiment component accepts effect $(repr(effect)); pass IgnoreUnknownEffects() explicitly to discard unknown effects",
))

"""Public extension boundary for physiological state carried by an `Embodiment`."""
abstract type AbstractPhysiology end

physiology_ports(::AbstractPhysiology) = Port{NoPlacement}[]
physiology_alive(::AbstractPhysiology) = true
physiology_feedback!(::AbstractPhysiology) = Float64[]
function physiology_feedback!(destination::AbstractVector, physiology::AbstractPhysiology)
    feedback = physiology_feedback!(physiology)
    length(destination) == length(feedback) || throw(DimensionMismatch(
        "physiology feedback destination has length $(length(destination)); " *
        "expected $(length(feedback))",
    ))
    copyto!(destination, feedback)
    return destination
end
physiology_state(::AbstractPhysiology) = NamedTuple()
physiology_reset!(::AbstractPhysiology) = nothing
physiology_link_profile(::AbstractPhysiology, default_probability::Real) = Float64[]

struct NoPhysiology{P<:UnknownEffectPolicy} <: AbstractPhysiology
    unknown_effects::P
end
NoPhysiology(; unknown_effects::UnknownEffectPolicy=RejectUnknownEffects()) =
    NoPhysiology(unknown_effects)
physiology_ports(::NoPhysiology) = Port{NoPlacement}[]
physiology_alive(::NoPhysiology) = true
physiology_feedback!(::NoPhysiology) = Float64[]
function physiology_feedback!(destination::AbstractVector, ::NoPhysiology)
    isempty(destination) || throw(DimensionMismatch(
        "NoPhysiology requires an empty feedback destination",
    ))
    return destination
end
physiology_state(::NoPhysiology) = NamedTuple()
function physiology_update!(physiology::NoPhysiology, effects)
    for effect in effects
        physiology_expose!(physiology, effect)
    end
    return nothing
end
physiology_expose!(physiology::NoPhysiology, effect) =
    _handle_unknown_effect(physiology.unknown_effects, effect)
physiology_reset!(::NoPhysiology) = nothing
physiology_link_profile(::NoPhysiology, default_probability::Real) = Float64[]

"""A component value paired with a stable, type-level identity."""
struct ComponentSlot{ID,V}
    value::V
end
ComponentSlot(id::Symbol, value) = ComponentSlot{id,typeof(value)}(value)
component_id(::ComponentSlot{ID}) where {ID} = ID
component_value(slot::ComponentSlot) = slot.value

"""Mutable runtime-owned state separated from immutable embodiment policy."""
struct EmbodimentState{I,C,E,P,B,U}
    ids::I
    commands::C
    encoder_groups::E
    port_spec::P
    receptor_buffer::B
    user::U
end

"""
    Embodiment(; geometry, sensors, encoders, actuators, dynamics, physiology, traits, state)

The single composed body type. Biological and robotic embodiments differ only
in their component values; no morphology or organism subclass is required.
"""
struct Embodiment{G<:AbstractGeometry,S<:Tuple,E<:Tuple,R<:Tuple,A<:Tuple,D<:AbstractDynamics,P<:AbstractPhysiology,T,St} <: AbstractBody
    geometry::G
    sensors::S
    encoders::E
    readouts::R
    actuators::A
    dynamics::D
    physiology::P
    traits::T
    state::St
end

function Embodiment(;
    geometry::AbstractGeometry=NoGeometry(),
    sensors=(DirectRelaySensor(0),),
    encoders=(IdentityEncoder(0; prefix=:direct),),
    readouts=nothing,
    actuators=(DirectRelayActuator(1),),
    dynamics::AbstractDynamics=NoDynamics(),
    physiology::AbstractPhysiology=NoPhysiology(),
    traits=NamedTuple(),
    state=NamedTuple(),
    component_ids=nothing,
)
    sensors_ = Tuple(sensors)
    encoders_ = Tuple(encoders)
    actuators_ = Tuple(actuators)
    readouts_ = readouts === nothing ? _default_readouts(actuators_) : Tuple(readouts)
    isempty(sensors_) && throw(ArgumentError("Embodiment requires at least one sensor component"))
    isempty(encoders_) && throw(ArgumentError("Embodiment requires at least one encoder component"))
    length(readouts_) == 1 || throw(ArgumentError(
        "the standard Embodiment runtime currently requires exactly one readout component",
    ))
    isempty(actuators_) && throw(ArgumentError("Embodiment requires at least one actuator component"))
    all(sensor -> sensor isa AbstractSensor, sensors_) ||
        throw(ArgumentError("Embodiment sensors must all subtype AbstractSensor"))
    all(encoder -> encoder isa AbstractEncoder, encoders_) ||
        throw(ArgumentError("Embodiment encoders must all subtype AbstractEncoder"))
    all(readout -> readout isa AbstractReadout, readouts_) ||
        throw(ArgumentError("Embodiment readouts must all subtype AbstractReadout"))
    all(actuator -> actuator isa AbstractActuator, actuators_) ||
        throw(ArgumentError("Embodiment actuators must all subtype AbstractActuator"))
    ids = _normalize_component_ids(
        component_ids,
        length(sensors_),
        length(encoders_),
        length(readouts_),
        length(actuators_),
    )
    encoders_, encoder_ids = _complete_encoder_components(
        sensors_, encoders_, ids.sensors, ids.encoders,
    )
    ids = _normalize_component_ids((;
        ids...,
        encoders=encoder_ids,
    ), length(sensors_), length(encoders_), length(readouts_), length(actuators_))
    encoder_groups = _encoder_groups(sensors_, encoders_, ids.sensors, ids.encoders)
    commands = Tuple(command_buffer(actuator) for actuator in actuators_)
    port_spec = _embodiment_portspec(ids, encoder_groups, actuators_, physiology)
    receptor_buffer = zeros(Float64, n_receptors(port_spec))
    state_ = EmbodimentState(
        ids,
        commands,
        encoder_groups,
        port_spec,
        receptor_buffer,
        state,
    )
    return Embodiment{typeof(geometry),typeof(sensors_),typeof(encoders_),typeof(readouts_),typeof(actuators_),typeof(dynamics),typeof(physiology),typeof(traits),typeof(state_)}(
        geometry,
        sensors_,
        encoders_,
        readouts_,
        actuators_,
        dynamics,
        physiology,
        traits,
        state_,
    )
end

function _default_readouts(actuators::Tuple)
    policy = length(actuators) == 1 ? readout_policy(only(actuators)) : PASSTHROUGH_MOTOR
    return (MeanReadout(policy),)
end

function _sensor_identity_port_ids(sensor_id::Symbol, sensor::AbstractSensor)
    spec = applicable(portspec, sensor) ? portspec(sensor) : nothing
    width = _raw_width(sensor)
    if spec !== nothing && n_receptors(spec) == width
        return Tuple(Symbol(sensor_id, :__, port.id) for port in spec.receptor_ports)
    end
    return ntuple(index -> Symbol(sensor_id, :__raw_, index), width)
end

function _declared_encoder_sources(encoder::AbstractEncoder)
    sources = encoder_sources(encoder)
    sources === nothing && return nothing
    sources_ = Tuple(Symbol(id) for id in sources)
    isempty(sources_) && throw(ArgumentError(
        "encoder source declarations must contain at least one stable sensor ID",
    ))
    length(unique(sources_)) == length(sources_) || throw(ArgumentError(
        "encoder source declarations must not repeat a sensor ID; got $(sources_)",
    ))
    return sources_
end

function _complete_encoder_components(
    sensors::Tuple,
    encoders::Tuple,
    sensor_ids::Tuple,
    encoder_ids::Tuple,
)
    declarations = map(_declared_encoder_sources, encoders)
    any(source -> source !== nothing, declarations) || return encoders, encoder_ids
    all(source -> source !== nothing, declarations) || throw(ArgumentError(
        "source-aware and conventionally grouped encoders cannot be mixed; " *
        "implement encoder_sources for every encoder in this composition",
    ))

    claimed = Symbol[]
    for sources in declarations, sensor_id in sources
        sensor_id in sensor_ids || throw(ArgumentError(
            "encoder references missing sensor :$(sensor_id)",
        ))
        sensor_id in claimed && throw(ArgumentError(
            "sensor :$(sensor_id) is claimed by more than one encoder",
        ))
        push!(claimed, sensor_id)
    end
    unclaimed_indices = Tuple(
        index for (index, sensor_id) in pairs(sensor_ids) if !(sensor_id in claimed)
    )
    automatic = map(unclaimed_indices) do index
        sensor_id = sensor_ids[index]
        encoder_id = Symbol(sensor_id, :__identity_encoder)
        encoder = IdentityEncoder(
            _sensor_identity_port_ids(sensor_id, sensors[index]);
            sources=(sensor_id,),
        )
        return (id=encoder_id, value=encoder)
    end
    completed_encoders = (encoders..., (entry.value for entry in automatic)...)
    completed_ids = (encoder_ids..., (entry.id for entry in automatic)...)
    return completed_encoders, completed_ids
end

_default_ids(prefix::Symbol, count::Int) = ntuple(i -> Symbol(prefix, :_, i), count)

function _normalize_component_ids(
    component_ids,
    nsensors::Int,
    nencoders::Int,
    nreadouts::Int,
    nactuators::Int,
)
    defaults = (
        geometry=:geometry,
        sensors=_default_ids(:sensor, nsensors),
        encoders=_default_ids(:encoder, nencoders),
        readouts=_default_ids(:readout, nreadouts),
        actuators=_default_ids(:actuator, nactuators),
        dynamics=:dynamics,
        physiology=:physiology,
    )
    ids = component_ids === nothing ? defaults : component_ids
    legacy_fields = (:geometry, :sensors, :encoders, :actuators, :dynamics, :physiology)
    if propertynames(ids) == legacy_fields
        ids = (
            geometry=ids.geometry,
            sensors=ids.sensors,
            encoders=ids.encoders,
            readouts=defaults.readouts,
            actuators=ids.actuators,
            dynamics=ids.dynamics,
            physiology=ids.physiology,
        )
    end
    required = propertynames(defaults)
    propertynames(ids) == required || throw(ArgumentError(
        "component_ids must have fields $(required), got $(propertynames(ids))",
    ))
    sensors = Tuple(Symbol(id) for id in ids.sensors)
    encoders = Tuple(Symbol(id) for id in ids.encoders)
    readouts = Tuple(Symbol(id) for id in ids.readouts)
    actuators = Tuple(Symbol(id) for id in ids.actuators)
    length(sensors) == nsensors || throw(DimensionMismatch("sensor component ID count does not match sensors"))
    length(encoders) == nencoders || throw(DimensionMismatch("encoder component ID count does not match encoders"))
    length(readouts) == nreadouts || throw(DimensionMismatch("readout component ID count does not match readouts"))
    length(actuators) == nactuators || throw(DimensionMismatch("actuator component ID count does not match actuators"))
    normalized = (
        geometry=Symbol(ids.geometry),
        sensors=sensors,
        encoders=encoders,
        readouts=readouts,
        actuators=actuators,
        dynamics=Symbol(ids.dynamics),
        physiology=Symbol(ids.physiology),
    )
    all_ids = (
        normalized.geometry,
        normalized.sensors...,
        normalized.encoders...,
        normalized.readouts...,
        normalized.actuators...,
        normalized.dynamics,
        normalized.physiology,
    )
    length(unique(all_ids)) == length(all_ids) || throw(ArgumentError(
        "embodiment component IDs must be globally unique; got $(all_ids)",
    ))
    return normalized
end

function direct_embodiment(n_receptors::Integer, n_effectors::Integer; kwargs...)
    return Embodiment(;
        sensors=(DirectRelaySensor(n_receptors),),
        encoders=(IdentityEncoder(n_receptors; prefix=:direct),),
        actuators=(DirectRelayActuator(n_effectors),),
        component_ids=(
            geometry=:direct_geometry,
            sensors=(:direct_sensor,),
            encoders=(:direct_encoder,),
            actuators=(:direct_actuator,),
            dynamics=:direct_dynamics,
            physiology=:physiology,
        ),
        kwargs...,
    )
end

function situated_embodiment(
    layout::SituatedSensorLayout,
    policy::KinematicMotor=KinematicMotor();
    radius::Real=0.5,
    physiology=NoPhysiology(),
    traits=NamedTuple(),
    state=NamedTuple(),
)
    return Embodiment(;
        geometry=DiscGeometry(radius),
        sensors=(layout,),
        encoders=(SituatedEncoder(layout),),
        actuators=(SituatedActuator(policy; signalling=layout.signalling),),
        dynamics=NoDynamics(),
        physiology=physiology,
        traits=traits,
        state=state,
        component_ids=(
            geometry=:situated_geometry,
            sensors=(:situated_sensor,),
            encoders=(:situated_encoder,),
            actuators=(:situated_actuator,),
            dynamics=:situated_dynamics,
            physiology=:physiology,
        ),
    )
end

sensor_components(body::Embodiment) = body.sensors
encoder_components(body::Embodiment) = body.encoders
readout_components(body::Embodiment) = body.readouts
actuator_components(body::Embodiment) = body.actuators
function component_slots(body::Embodiment)
    ids = body.state.ids
    return (
        geometry=ComponentSlot(ids.geometry, body.geometry),
        sensors=Tuple(ComponentSlot(id, value) for (id, value) in zip(ids.sensors, body.sensors)),
        encoders=Tuple(ComponentSlot(id, value) for (id, value) in zip(ids.encoders, body.encoders)),
        readouts=Tuple(ComponentSlot(id, value) for (id, value) in zip(ids.readouts, body.readouts)),
        actuators=Tuple(ComponentSlot(id, value) for (id, value) in zip(ids.actuators, body.actuators)),
        dynamics=ComponentSlot(ids.dynamics, body.dynamics),
        physiology=ComponentSlot(ids.physiology, body.physiology),
    )
end
situated_sensor(body::AbstractBody) = throw(ArgumentError(
    "situated sensing requires an Embodiment with one SituatedSensorLayout component; got $(typeof(body))",
))
situated_sensor(body::Embodiment) = only(body.sensors)
primary_actuator(body::Embodiment) = only(body.actuators)
primary_readout(body::Embodiment) = only(body.readouts)
readout_policy(body::Embodiment) = readout_policy(primary_readout(body))

_namespaced_port(component_id::Symbol, port) =
    Port{Any}(Symbol(component_id, :__, port.id), port.placement)

function _component_ports(components, ids, side::Symbol)
    output = Port{Any}[]
    for (component_id, component) in zip(ids, components)
        spec = portspec(component)
        selected = side === :receptor ? spec.receptor_ports : spec.effector_ports
        append!(output, (_namespaced_port(component_id, port) for port in selected))
    end
    return output
end

function _encoder_groups(sensors::Tuple, encoders::Tuple, sensor_ids::Tuple, encoder_ids::Tuple)
    declarations = map(_declared_encoder_sources, encoders)
    if all(source -> source !== nothing, declarations)
        claimed = Int[]
        groups = map(encoder_ids, encoders, declarations) do encoder_id, encoder, sources
            indices = map(sources) do sensor_id
                index = findfirst(==(sensor_id), sensor_ids)
                index === nothing && throw(ArgumentError(
                    "encoder :$(encoder_id) references missing sensor :$(sensor_id)",
                ))
                index in claimed && throw(ArgumentError(
                    "sensor :$(sensor_id) is claimed by more than one encoder",
                ))
                push!(claimed, index)
                index
            end
            selected = Tuple(sensors[index] for index in indices)
            return (encoder_id, encoder, selected, indices)
        end
        length(claimed) == length(sensors) || throw(ArgumentError(
            "source-aware encoders leave one or more sensors unencoded",
        ))
        return groups
    elseif any(source -> source !== nothing, declarations)
        throw(ArgumentError(
            "source-aware and conventionally grouped encoders cannot be mixed",
        ))
    elseif length(encoders) == 1
        encoder = only(encoders)
        indices = Tuple(eachindex(sensors))
        selected = Tuple(sensors[index] for index in indices)
        return ((only(encoder_ids), encoder, selected, indices),)
    elseif length(encoders) == length(sensors)
        return Tuple(
            (encoder_id, encoder, (sensor,), (index,))
            for (index, (encoder_id, encoder, sensor)) in
                enumerate(zip(encoder_ids, encoders, sensors))
        )
    end
    throw(DimensionMismatch(
        "Embodiment needs either one encoder for all sensors or one encoder per sensor; " *
        "got $(length(encoders)) encoders and $(length(sensors)) sensors",
    ))
end

_encoder_groups(body::Embodiment) = body.state.encoder_groups

function _raw_width(sensor::AbstractSensor)
    spec = rawspec(sensor)
    hasproperty(spec, :width) || throw(ArgumentError(
        "rawspec for $(typeof(sensor)) must declare a :width",
    ))
    width = Int(spec.width)
    width >= 0 || throw(ArgumentError("raw sensor width must be non-negative"))
    return width
end

function _bilateral_encoder_ports(encoder::AbstractBilateralEncoder, sensors::Tuple)
    length(sensors) == 2 || throw(DimensionMismatch("bilateral encoders require exactly two sensors"))
    left_width, right_width = _raw_width.(sensors)
    left_width == right_width || throw(DimensionMismatch(
        "bilateral sensors must have equal raw widths, got $(left_width) and $(right_width)",
    ))
    raw_width = left_width + right_width
    encoded_width = encoder isa RawBilateralEncoder ? raw_width : raw_width ÷ 2
    receptors = Port{NoPlacement}[
        Port(Symbol(:bilateral_, i)) for i in 1:encoded_width
    ]
    return PortSpec(encoded_width, 0, receptors, Port{NoPlacement}[])
end

_encoder_portspec(encoder::AbstractBilateralEncoder, sensors::Tuple) =
    _bilateral_encoder_ports(encoder, sensors)
_encoder_portspec(encoder::AbstractEncoder, sensors::Tuple) = portspec(encoder)

function _encoder_receptor_ports(encoder_groups)
    output = Port{Any}[]
    for (encoder_id, encoder, sensors, _) in encoder_groups
        spec = _encoder_portspec(encoder, sensors)
        append!(output, (_namespaced_port(encoder_id, port) for port in spec.receptor_ports))
    end
    return output
end

function _embodiment_portspec(ids, encoder_groups, actuators, physiology)
    receptors = _encoder_receptor_ports(encoder_groups)
    append!(receptors, (
        _namespaced_port(ids.physiology, port)
        for port in physiology_ports(physiology)
    ))
    effectors = _component_ports(actuators, ids.actuators, :effector)
    return PortSpec(length(receptors), length(effectors), receptors, effectors)
end

portspec(body::Embodiment) = body.state.port_spec
n_receptors(body::Embodiment) = body.state.port_spec.n_receptors
n_effectors(body::Embodiment) = body.state.port_spec.n_effectors
rawspec(body::Embodiment) = NamedTuple{body.state.ids.sensors}(
    Tuple(rawspec(sensor) for sensor in body.sensors),
)

function _sensor_samples(body::Embodiment, percept)
    length(body.sensors) == 1 && return (percept,)
    samples = percept isa Tuple ? percept : Tuple(percept)
    length(samples) == length(body.sensors) || throw(DimensionMismatch(
        "Embodiment has $(length(body.sensors)) sensor components but received $(length(samples)) samples",
    ))
    return samples
end

function _flatten_raw_samples(samples::Tuple)
    return reduce(vcat, (_component_float_vector(sample) for sample in samples); init=Float64[])
end

function _encoder_input(encoder::SituatedEncoder, sensors::Tuple, samples::Tuple)
    length(sensors) == length(samples) == 1 || throw(DimensionMismatch(
        "SituatedEncoder consumes exactly one SituatedSensorLayout",
    ))
    only(sensors) isa SituatedSensorLayout || throw(ArgumentError(
        "SituatedEncoder requires a SituatedSensorLayout sensor",
    ))
    return only(samples)
end


function _encoder_input(encoder::AbstractBilateralEncoder, sensors::Tuple, samples::Tuple)
    length(sensors) == length(samples) == 2 || throw(DimensionMismatch(
        "bilateral encoders consume exactly two sensor sample vectors",
    ))
    left = _component_float_vector(samples[1])
    right = _component_float_vector(samples[2])
    length(left) == _raw_width(sensors[1]) || throw(DimensionMismatch("left sensor sample width mismatch"))
    length(right) == _raw_width(sensors[2]) || throw(DimensionMismatch("right sensor sample width mismatch"))
    length(left) == length(right) || throw(DimensionMismatch("bilateral sample widths must match"))
    paired = Vector{Float64}(undef, 2length(left))
    @inbounds for channel in eachindex(left)
        paired[2channel - 1] = left[channel]
        paired[2channel] = right[channel]
    end
    return paired
end

function _encoder_input(encoder::AbstractEncoder, sensors::Tuple, samples::Tuple)
    expected = sum(_raw_width, sensors; init=0)
    raw = _flatten_raw_samples(samples)
    length(raw) == expected || throw(DimensionMismatch(
        "raw sensor group declared width $(expected), got $(length(raw)) samples",
    ))
    return raw
end

function _encode_group(encoder::AbstractEncoder, sensors::Tuple, samples::Tuple)
    return encode!(encoder, _encoder_input(encoder, sensors, samples))
end

struct EmbodimentEncodingState{G}
    groups::G
    feedback_width::Int
end

function begin_encoding!(body::Embodiment, percept, cycle::FixedRateCycle)
    samples = _sensor_samples(body, percept)
    groups = map(_encoder_groups(body)) do (_, encoder, sensors, indices)
        selected_samples = Tuple(samples[index] for index in indices)
        input = _encoder_input(encoder, sensors, selected_samples)
        begin_encoding!(encoder, input, cycle)
    end
    sensor_width = sum(
        n_receptors(_encoder_portspec(group[2], group[3]))
        for group in _encoder_groups(body);
        init=0,
    )
    feedback_width = length(body.state.receptor_buffer) - sensor_width
    feedback_width >= 0 || throw(DimensionMismatch(
        "Embodiment encoders expose $(sensor_width) receptors, but its cached port " *
        "contract has width $(length(body.state.receptor_buffer))",
    ))
    feedback = @view body.state.receptor_buffer[(sensor_width + 1):end]
    physiology_feedback!(feedback, body.physiology)
    return EmbodimentEncodingState(groups, feedback_width)
end

function _encoded_sensor_frame!(
    output::Vector{Float64},
    body::Embodiment,
    encoding_states::Tuple,
    frame::Integer,
    cycle::FixedRateCycle,
)
    length(encoding_states) == length(_encoder_groups(body)) || throw(DimensionMismatch(
        "Embodiment has $(length(_encoder_groups(body))) encoder groups but received " *
        "$(length(encoding_states)) encoding states",
    ))
    offset = 0
    for ((_, encoder, _, _), encoding_state) in zip(_encoder_groups(body), encoding_states)
        encoded = _component_float_vector(encode_frame!(encoder, encoding_state, frame, cycle))
        copyto!(output, offset + 1, encoded, 1, length(encoded))
        offset += length(encoded)
    end
    return offset
end

function encode_frame!(
    body::Embodiment,
    state::EmbodimentEncodingState,
    frame::Integer,
    cycle::FixedRateCycle,
)
    1 <= frame <= neural_frames(cycle) || throw(BoundsError(1:neural_frames(cycle), frame))
    output = body.state.receptor_buffer
    base_width = _encoded_sensor_frame!(output, body, state.groups, frame, cycle)
    feedback_width = length(output) - base_width
    feedback_width == state.feedback_width || throw(DimensionMismatch(
        "Embodiment frame requires $(feedback_width) physiology receptors, but the " *
        "held feedback state has $(state.feedback_width)",
    ))
    physiology_alive(body.physiology) || fill!(output, 0.0)
    return output
end

function sense!(body::Embodiment, percept)
    cycle = FixedRateCycle(1)
    state = begin_encoding!(body, percept, cycle)
    return encode_frame!(body, state, 1, cycle)
end

function decode!(body::Embodiment, values)
    length(values) == n_effectors(body) || throw(DimensionMismatch(
        "Embodiment expected $(n_effectors(body)) effectors, got $(length(values))",
    ))
    offset = 0
    for index in eachindex(body.actuators)
        actuator = body.actuators[index]
        command = body.state.commands[index]
        width = n_effectors(actuator)
        decode!(command, actuator, @view(values[(offset + 1):(offset + width)]))
        offset += width
    end
    return length(body.state.commands) == 1 ? only(body.state.commands) : body.state.commands
end

alive(body::Embodiment) = physiology_alive(body.physiology)
inactive_command(body::Embodiment) = begin
    foreach(reset_command!, body.state.commands)
    length(body.state.commands) == 1 ? only(body.state.commands) : body.state.commands
end
expose!(body::Embodiment, effect) = physiology_expose!(body.physiology, effect)
function update!(body::Embodiment, effects=())
    physiology_update!(body.physiology, effects)
    return nothing
end
function reset!(body::Embodiment)
    for component in (
        body.sensors...,
        body.encoders...,
        body.readouts...,
        body.actuators...,
        body.dynamics,
    )
        applicable(reset!, component) && reset!(component)
    end
    applicable(reset!, body.state.user) && reset!(body.state.user)
    foreach(reset_command!, body.state.commands)
    fill!(body.state.receptor_buffer, 0.0)
    physiology_reset!(body.physiology)
    return body
end
component_state(::AbstractBody) = NamedTuple()
_component_runtime_state(component) =
    applicable(component_state, component) ? component_state(component) : NamedTuple()

function _component_states(body::Embodiment)
    slots = component_slots(body)
    flattened = (
        slots.geometry,
        slots.sensors...,
        slots.encoders...,
        slots.readouts...,
        slots.actuators...,
        slots.dynamics,
        slots.physiology,
    )
    ids = Tuple(component_id(slot) for slot in flattened)
    values = Tuple(_component_runtime_state(component_value(slot)) for slot in flattened)
    return NamedTuple{ids}(values)
end

component_state(body::Embodiment) = (
    body=body.state.user,
    components=_component_states(body),
    physiology=physiology_state(body.physiology),
    physiology_state(body.physiology)...,
)

function receptor_link_profile(body::Embodiment, default_probability::Real)
    probabilities = Float64[]
    for (_, encoder, sensors, _) in _encoder_groups(body)
        width = n_receptors(_encoder_portspec(encoder, sensors))
        append!(probabilities, fill(Float64(default_probability), width))
        if encoder isa SituatedEncoder
            layout = encoder.layout
            offset = length(probabilities) - sum(bank_width, layout.sensory_banks; init=0)
            for bank in layout.sensory_banks
                width_ = bank_width(bank)
                bank.link_p === nothing ||
                    (probabilities[(offset + 1):(offset + width_)] .= bank.link_p)
                offset += width_
            end
        end
    end
    append!(probabilities, physiology_link_profile(body.physiology, default_probability))
    all(==(Float64(default_probability)), probabilities) && return nothing
    return probabilities
end
