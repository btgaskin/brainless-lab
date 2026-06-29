struct Agent{R<:Reservoir,B<:Body}
    reservoir::R
    body::B
end

mutable struct Collective{M<:Medium}
    agents::Vector{<:Agent}
    medium::M
    t::Int
    recorder
end

function Collective(
    agents::AbstractVector{<:Agent},
    medium::M;
    t::Integer=0,
    recorder=nothing,
) where {M<:Medium}
    isempty(agents) && throw(ArgumentError("Collective requires at least one agent"))
    return Collective{M}(collect(agents), medium, Int(t), recorder)
end

_agent_bodies(c::Collective) = [agent.body for agent in c.agents]

function _spike_rate(spikes)
    values = Float64.(vec(collect(spikes)))
    isempty(values) && return 0.0
    return sum(values) / length(values)
end

function _record_payload(x)
    if x isa AbstractArray && eltype(x) <: Number
        return copy(x)
    elseif x isa AbstractVector
        return [_record_payload(v) for v in x]
    elseif x isa Tuple
        return map(_record_payload, x)
    end
    return x
end

function _record_collective!(rec, percepts, spikes, rates, Es)
    record!(rec, :spikes, _record_payload(spikes))
    record!(rec, :rates, copy(rates))
    record!(rec, :effectors, _record_payload(Es))
    record!(rec, :percepts, _record_payload(percepts))
    tick!(rec)
    return rec
end

function step!(c::Collective)
    bodies = _agent_bodies(c)
    percepts = observe(c.medium, bodies)
    length(percepts) == length(c.agents) ||
        throw(DimensionMismatch("medium returned $(length(percepts)) percepts for $(length(c.agents)) agents"))

    spikes = Vector{Any}(undef, length(c.agents))
    rates = Vector{Float64}(undef, length(c.agents))
    Es = Vector{Any}(undef, length(c.agents))

    @inbounds for i in eachindex(c.agents)
        agent = c.agents[i]
        R = receptors(agent.body, percepts[i])
        s = step!(agent.reservoir, R)
        E = effectors(agent.reservoir, s)
        spikes[i] = s
        rates[i] = _spike_rate(s)
        Es[i] = motor(agent.body, E)
    end

    actuate!(c.medium, bodies, Es)
    c.t += 1

    if c.recorder !== nothing
        _record_collective!(c.recorder, percepts, spikes, rates, Es)
    end

    return spikes
end

function _rollout_rate_and_width(spikes)
    total = 0.0
    width = 0
    for s in spikes
        values = Float64.(vec(collect(s)))
        total += sum(values)
        width += length(values)
    end
    return width == 0 ? 0.0 : total / width, width
end

function rollout!(c::Collective, ticks::Integer; window::Integer=ticks)
    ticks = Int(ticks)
    ticks >= 0 || throw(ArgumentError("ticks must be non-negative"))
    window = Int(window)

    rates = zeros(Float64, ticks)
    node_count = 0
    for t in 1:ticks
        spikes = step!(c)
        rates[t], width = _rollout_rate_and_width(spikes)
        node_count = max(node_count, width)
    end

    return (;
        medium_metrics(c.medium, window)...,
        liveness(rates, node_count, window)...,
    )
end
