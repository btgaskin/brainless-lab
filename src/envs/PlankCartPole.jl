const PLANK_CARTPOLE_MISSION_STEPS = 15_000
const PLANK_CARTPOLE_NEURAL_FRAMES = 24
const PLANK_CARTPOLE_EVAL_EPISODES = 1_000

"""Frozen task-interface definition for one experimental Plank CartPole level."""
struct PlankCartPoleLevel
    name::Symbol
    observation_indices::Tuple{Vararg{Int}}
    actions::Tuple{Vararg{Symbol}}
    encoder::Symbol
    target_fitness::Float64
    activity_threshold::Union{Nothing,Float64}
end

const PLANK_CARTPOLE_LEVELS = (
    easy=PlankCartPoleLevel(
        :easy,
        (1, 2, 3, 4),
        (:left, :right),
        :spike_ff_2,
        14_250.0,
        nothing,
    ),
    medium=PlankCartPoleLevel(
        :medium,
        (1, 2, 3, 4),
        (:noop, :left, :right),
        :spike_ff_2,
        12_000.0,
        0.75,
    ),
    hard=PlankCartPoleLevel(
        :hard,
        (1, 3),
        (:noop, :left, :right),
        :spike_ff_2,
        9_000.0,
        nothing,
    ),
    hardest=PlankCartPoleLevel(
        :hardest,
        (1, 3),
        (:left, :right),
        :argyle_4,
        6_000.0,
        nothing,
    ),
)

function plank_cartpole_level(level::Union{Symbol,AbstractString,PlankCartPoleLevel})
    level isa PlankCartPoleLevel && return level
    name = Symbol(level)
    hasproperty(PLANK_CARTPOLE_LEVELS, name) || throw(ArgumentError(
        "unknown Plank CartPole level :$(name); use :easy, :medium, :hard, or :hardest",
    ))
    return getproperty(PLANK_CARTPOLE_LEVELS, name)
end

const _PLANK_CARTPOLE_SCALES = (2.4, 2.0, 0.2095, 2.0)

"""Two-bin flip-flop temporal spike encoder used by Easy, Medium, and Hard."""
struct SpikeFF2Encoder{N,P<:Tuple,S<:Tuple} <: AbstractEncoder
    scales::NTuple{N,Float64}
    port_ids::P
    source_ids::S
end

function SpikeFF2Encoder(scales; prefix::Symbol=:cartpole, sources=())
    scales_ = Tuple(Float64(scale) for scale in scales)
    all(scale -> isfinite(scale) && scale > 0.0, scales_) || throw(ArgumentError(
        "SpikeFF2Encoder scales must be finite and positive",
    ))
    n = length(scales_)
    ids = ntuple(2n) do index
        observation = cld(index, 2)
        sign = isodd(index) ? :negative : :positive
        Symbol(prefix, :_, observation, :_, sign)
    end
    source_ids = Tuple(Symbol(source) for source in sources)
    return SpikeFF2Encoder{n,typeof(ids),typeof(source_ids)}(
        scales_,
        ids,
        source_ids,
    )
end

encoder_sources(encoder::SpikeFF2Encoder) =
    isempty(encoder.source_ids) ? nothing : encoder.source_ids
n_receptors(encoder::SpikeFF2Encoder) = length(encoder.port_ids)
portspec(encoder::SpikeFF2Encoder) = PortSpec(
    n_receptors(encoder),
    0,
    Port{NoPlacement}[Port(id) for id in encoder.port_ids],
    Port{NoPlacement}[],
)

mutable struct SpikeFF2State
    counts::Vector{Int}
    bins::Vector{Int}
    frame::Vector{Float64}
end

function begin_encoding!(encoder::SpikeFF2Encoder, samples, cycle::FixedRateCycle)
    neural_frames(cycle) == PLANK_CARTPOLE_NEURAL_FRAMES || throw(ArgumentError(
        "SpikeFF2Encoder protocol requires $(PLANK_CARTPOLE_NEURAL_FRAMES) neural frames, " *
        "got $(neural_frames(cycle))",
    ))
    values = _component_float_vector(samples)
    length(values) == length(encoder.scales) || throw(DimensionMismatch(
        "SpikeFF2Encoder expected $(length(encoder.scales)) observations, got $(length(values))",
    ))
    counts = Vector{Int}(undef, length(values))
    bins = Vector{Int}(undef, length(values))
    @inbounds for index in eachindex(values)
        value = Float64(values[index])
        isfinite(value) || throw(ArgumentError("CartPole observation $(index) must be finite"))
        counts[index] = clamp(ceil(Int, 8.0 * abs(value) / encoder.scales[index]), 0, 8)
        bins[index] = 2index - (value <= 0.0 ? 1 : 0)
    end
    return SpikeFF2State(counts, bins, zeros(n_receptors(encoder)))
end

function encode_frame!(
    ::SpikeFF2Encoder,
    state::SpikeFF2State,
    frame::Integer,
    cycle::FixedRateCycle,
)
    1 <= frame <= neural_frames(cycle) || throw(BoundsError(1:neural_frames(cycle), frame))
    fill!(state.frame, 0.0)
    # Authors' processor schedule uses Apply_Spike times 0, 3, ..., 21 followed
    # by RUN 24. Julia frame 1 represents processor time 0.
    slot = rem(frame - 1, 3) == 0 ? div(frame - 1, 3) + 1 : 0
    if 1 <= slot <= 8
        @inbounds for index in eachindex(state.counts)
            slot <= state.counts[index] && (state.frame[state.bins[index]] = 1.0)
        end
    end
    return state.frame
end

"""Four-bin adjacent population encoder with nine conserved spikes per value."""
struct Argyle4Encoder{N,P<:Tuple,S<:Tuple} <: AbstractEncoder
    minima::NTuple{N,Float64}
    maxima::NTuple{N,Float64}
    port_ids::P
    source_ids::S
end

function Argyle4Encoder(scales; prefix::Symbol=:cartpole, sources=())
    scales_ = Tuple(Float64(scale) for scale in scales)
    all(scale -> isfinite(scale) && scale > 0.0, scales_) || throw(ArgumentError(
        "Argyle4Encoder scales must be finite and positive",
    ))
    n = length(scales_)
    ids = ntuple(4n) do index
        observation = cld(index, 4)
        bin = mod1(index, 4)
        Symbol(prefix, :_, observation, :_bin_, bin)
    end
    source_ids = Tuple(Symbol(source) for source in sources)
    return Argyle4Encoder{n,typeof(ids),typeof(source_ids)}(
        ntuple(index -> -scales_[index], n),
        scales_,
        ids,
        source_ids,
    )
end

encoder_sources(encoder::Argyle4Encoder) =
    isempty(encoder.source_ids) ? nothing : encoder.source_ids
n_receptors(encoder::Argyle4Encoder) = length(encoder.port_ids)
portspec(encoder::Argyle4Encoder) = PortSpec(
    n_receptors(encoder),
    0,
    Port{NoPlacement}[Port(id) for id in encoder.port_ids],
    Port{NoPlacement}[],
)

mutable struct Argyle4State
    first_bins::Vector{Int}
    first_counts::Vector{Int}
    second_bins::Vector{Int}
    second_counts::Vector{Int}
    frame::Vector{Float64}
end

function begin_encoding!(encoder::Argyle4Encoder, samples, cycle::FixedRateCycle)
    neural_frames(cycle) == PLANK_CARTPOLE_NEURAL_FRAMES || throw(ArgumentError(
        "Argyle4Encoder protocol requires $(PLANK_CARTPOLE_NEURAL_FRAMES) neural frames, " *
        "got $(neural_frames(cycle))",
    ))
    values = _component_float_vector(samples)
    length(values) == length(encoder.minima) || throw(DimensionMismatch(
        "Argyle4Encoder expected $(length(encoder.minima)) observations, got $(length(values))",
    ))
    first_bins = Vector{Int}(undef, length(values))
    first_counts = Vector{Int}(undef, length(values))
    second_bins = Vector{Int}(undef, length(values))
    second_counts = Vector{Int}(undef, length(values))
    @inbounds for index in eachindex(values)
        value = Float64(values[index])
        isfinite(value) || throw(ArgumentError("CartPole observation $(index) must be finite"))
        p = clamp(
            (value - encoder.minima[index]) /
            (encoder.maxima[index] - encoder.minima[index]),
            0.0,
            1.0,
        )
        position = 3.0 * p
        local_first = min(floor(Int, position) + 1, 4)
        local_second = min(local_first + 1, 4)
        second_count = local_first == local_second ? 0 : round(Int, 9.0 * (position - floor(position)))
        first_bins[index] = 4(index - 1) + local_first
        second_bins[index] = 4(index - 1) + local_second
        second_counts[index] = clamp(second_count, 0, 9)
        first_counts[index] = 9 - second_counts[index]
    end
    return Argyle4State(
        first_bins,
        first_counts,
        second_bins,
        second_counts,
        zeros(n_receptors(encoder)),
    )
end

const _ARGYLE_9_FRAME_SCHEDULE = (1, 4, 7, 10, 13, 15, 18, 21, 24)

function encode_frame!(
    ::Argyle4Encoder,
    state::Argyle4State,
    frame::Integer,
    cycle::FixedRateCycle,
)
    1 <= frame <= neural_frames(cycle) || throw(BoundsError(1:neural_frames(cycle), frame))
    fill!(state.frame, 0.0)
    slot = findfirst(==(Int(frame)), _ARGYLE_9_FRAME_SCHEDULE)
    slot === nothing && return state.frame
    @inbounds for index in eachindex(state.first_counts)
        slot <= state.first_counts[index] && (state.frame[state.first_bins[index]] = 1.0)
        slot <= state.second_counts[index] && (state.frame[state.second_bins[index]] = 1.0)
    end
    return state.frame
end

mutable struct PlankCartPoleEnv{R} <: TaskWorld
    rng::R
    level::PlankCartPoleLevel
    tau::Float64
    gravity::Float64
    force_mag::Float64
    pole_length::Float64
    pole_mass::Float64
    cart_mass::Float64
    total_mass::Float64
    max_x::Float64
    max_theta::Float64
    initial_ranges::NTuple{4,NTuple{2,Float64}}
    state::Vector{Float64}
    step_count::Int
    noop_count::Int
    done::Bool
end

function PlankCartPoleEnv(;
    rng=Random.default_rng(),
    level=:easy,
    initial_ranges=((-1.2, 1.2), (-0.05, 0.05), (-0.10475, 0.10475), (-0.05, 0.05)),
)
    level_ = plank_cartpole_level(level)
    ranges = Tuple((Float64(range[1]), Float64(range[2])) for range in initial_ranges)
    length(ranges) == 4 || throw(DimensionMismatch("CartPole initial_ranges must contain four ranges"))
    all(range -> range[1] <= range[2], ranges) || throw(ArgumentError(
        "CartPole initial ranges must be ordered",
    ))
    state = [_cartpole_sample(rng, range) for range in ranges]
    return PlankCartPoleEnv(
        rng,
        level_,
        0.02,
        9.8,
        10.0,
        0.5,
        0.1,
        1.0,
        1.1,
        2.4,
        0.2095,
        ranges,
        state,
        0,
        0,
        false,
    )
end

PlankCartPoleEnv(seed::Integer; kwargs...) =
    PlankCartPoleEnv(; rng=MersenneTwister(seed), kwargs...)

n_receptors(environment::PlankCartPoleEnv) =
    environment.level.encoder === :argyle_4 ? 4length(environment.level.observation_indices) :
    2length(environment.level.observation_indices)
n_effectors(environment::PlankCartPoleEnv) = length(environment.level.actions)
default_ticks(::PlankCartPoleEnv) = PLANK_CARTPOLE_MISSION_STEPS
default_window(::PlankCartPoleEnv) = PLANK_CARTPOLE_MISSION_STEPS

function sense(environment::PlankCartPoleEnv)
    environment.done && return zeros(length(environment.level.observation_indices))
    return Float64[environment.state[index] for index in environment.level.observation_indices]
end

function _plank_cartpole_action(environment::PlankCartPoleEnv, effectors)
    values = _bounded_effectors(effectors, n_effectors(environment))
    _, winner = findmax(values)
    return environment.level.actions[winner]
end

function step!(environment::PlankCartPoleEnv, effectors)
    environment.done && return environment
    action = _plank_cartpole_action(environment, effectors)
    action === :noop && (environment.noop_count += 1)
    force = action === :left ? -environment.force_mag :
        action === :right ? environment.force_mag : 0.0
    _integrate_cartpole_state!(
        environment.state,
        force;
        tau=environment.tau,
        gravity=environment.gravity,
        pole_length=environment.pole_length,
        pole_mass=environment.pole_mass,
        total_mass=environment.total_mass,
        # The source protocol executes Gym/Gymnasium CartPole's default
        # explicit-Euler path. Keep this distinct from the legacy BrainlessLab
        # variants, which predate these task profiles.
        integrator=:euler,
    )
    environment.step_count += 1
    environment.done =
        abs(environment.state[1]) > environment.max_x ||
        abs(environment.state[3]) > environment.max_theta ||
        environment.step_count >= PLANK_CARTPOLE_MISSION_STEPS
    return environment
end

function reset!(environment::PlankCartPoleEnv)
    @inbounds for index in eachindex(environment.state)
        environment.state[index] = _cartpole_sample(environment.rng, environment.initial_ranges[index])
    end
    environment.step_count = 0
    environment.noop_count = 0
    environment.done = false
    return environment
end

"""Install one explicit four-value test state and clear episode counters."""
function set_plank_cartpole_state!(environment::PlankCartPoleEnv, state)
    values = Tuple(Float64(value) for value in state)
    length(values) == 4 || throw(DimensionMismatch(
        "Plank CartPole state must contain x, x_dot, theta, and theta_dot",
    ))
    all(isfinite, values) || throw(ArgumentError("Plank CartPole state values must be finite"))
    copyto!(environment.state, values)
    environment.step_count = 0
    environment.noop_count = 0
    environment.done = false
    return environment
end

function plank_cartpole_fitness(environment::PlankCartPoleEnv)
    threshold = environment.level.activity_threshold
    threshold === nothing && return Float64(environment.step_count)
    environment.step_count == 0 && return 0.0
    noop_fraction = environment.noop_count / environment.step_count
    return noop_fraction > threshold ?
        Float64(environment.step_count) :
        Float64(environment.noop_count / threshold)
end

function metrics(environment::PlankCartPoleEnv, window::Integer=PLANK_CARTPOLE_MISSION_STEPS)
    fitness = plank_cartpole_fitness(environment)
    return (
        name="cartpole_plank_$(environment.level.name)",
        score=fitness,
        fitness=fitness,
        mission_fraction=environment.step_count / PLANK_CARTPOLE_MISSION_STEPS,
        steps_balanced=environment.step_count,
        noop_count=environment.noop_count,
        noop_fraction=environment.step_count == 0 ? 0.0 : environment.noop_count / environment.step_count,
        target_fitness=environment.level.target_fitness,
        achieved=fitness >= environment.level.target_fitness,
        fell=environment.step_count < PLANK_CARTPOLE_MISSION_STEPS,
        xy_path=nothing,
    )
end

scene(environment::PlankCartPoleEnv) = (
    kind=:cartpole,
    x=environment.state[1],
    theta=environment.state[3],
    max_x=environment.max_x,
    pole_length=environment.pole_length,
)

"""Task setup that freezes the level's sensory, temporal, and motor interface."""
struct PlankCartPoleSetup
    level::PlankCartPoleLevel
end

function (setup::PlankCartPoleSetup)(;
    seed=0,
    rng=nothing,
    body=nothing,
    n_nodes=nothing,
    kwargs...,
)
    body === nothing || throw(ArgumentError(
        "Plank CartPole task profiles freeze their embodiment; register a separate " *
        "experimental task to change sensors, encoding, readout, or actuators",
    ))
    rng_ = rng === nothing ? MersenneTwister(Int(seed)) : rng
    environment = PlankCartPoleEnv(; rng=rng_, level=setup.level, kwargs...)
    indices = setup.level.observation_indices
    scales = Tuple(_PLANK_CARTPOLE_SCALES[index] for index in indices)
    sensor = DirectRelaySensor(length(indices))
    encoder = setup.level.encoder === :argyle_4 ?
        Argyle4Encoder(scales; sources=(:cartpole_state,)) :
        SpikeFF2Encoder(scales; sources=(:cartpole_state,))
    embodiment = Embodiment(;
        sensors=(sensor,),
        encoders=(encoder,),
        readouts=(VotingReadout(),),
        actuators=(DirectRelayActuator(setup.level.actions),),
        traits=(
            family=:plank_cartpole,
            level=setup.level.name,
            interface_frozen=true,
        ),
        component_ids=(
            geometry=:direct_geometry,
            sensors=(:cartpole_state,),
            encoders=(:cartpole_spike_encoder,),
            readouts=(:winner_take_all,),
            actuators=(:cartpole_action,),
            dynamics=:environment_dynamics,
            physiology=:physiology,
        ),
    )
    return TaskSetup(environment, [embodiment])
end
