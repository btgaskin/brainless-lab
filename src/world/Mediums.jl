"""
    TaskMedium(env)

Single-agent medium wrapper around one task `Environment`.
"""
struct TaskMedium{E<:Environment} <: Medium
    env::E
end

function _require_single_body(bodies)
    length(bodies) == 1 ||
        throw(ArgumentError("TaskMedium wraps one Environment and requires exactly one body"))
    return nothing
end

function observe(m::TaskMedium, bodies)
    _require_single_body(bodies)
    return [sense(m.env)]
end

function actuate!(m::TaskMedium, bodies, Es)
    _require_single_body(bodies)
    length(Es) == 1 ||
        throw(ArgumentError("TaskMedium requires exactly one effector command"))
    return step!(m.env, Es[1])
end

medium_metrics(m::TaskMedium, window::Integer=default_window(m.env)) =
    metrics(m.env, Int(window))
