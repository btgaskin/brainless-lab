_wrap_to_pi(a) = atan(sin(a), cos(a))

function _task_signal_environment_size(sim::SimResult, name::Symbol)
    if !hasproperty(sim.config, :environment)
        throw(ArgumentError("$(name) needs sim.config.environment.size to be available"))
    end
    environment = getproperty(sim.config, :environment)
    if !hasproperty(environment, :size) || getproperty(environment, :size) === nothing
        throw(ArgumentError("$(name) needs sim.config.environment.size to be available"))
    end
    return Float64(getproperty(environment, :size))
end

function _task_signal_first_pose(entry, name::Symbol)
    if !(entry isa AbstractVector) || isempty(entry)
        throw(ArgumentError("$(name) needs :poses entries shaped as vectors of (x, y, theta) tuples"))
    end
    pose = entry[1]
    if !((pose isa Tuple || pose isa AbstractVector) && length(pose) >= 2)
        throw(ArgumentError("$(name) needs :poses entries shaped as vectors of (x, y, theta) tuples"))
    end
    return pose
end

function _task_signal_scene(entry)
    if hasproperty(entry, :scene)
        return getproperty(entry, :scene)
    end
    return entry
end

function _task_signal_field(entry, field::Symbol, name::Symbol)
    scene_entry = _task_signal_scene(entry)
    if !hasproperty(scene_entry, field)
        throw(ArgumentError("$(name) needs :scene entries with field :$(field)"))
    end
    return Float64(getproperty(scene_entry, field))
end

"""
    wall_distance(sim)

Compute the per-tick distance from the wall-task agent to the nearest wall.
Requires the `:poses` channel.
"""
function wall_distance(sim::SimResult)
    poses = getchannel(sim.recorder, :poses)
    isempty(poses) && throw(ArgumentError("wall_distance needs :poses recorded; run simulate(...; record=(:rate, :poses))"))

    size = _task_signal_environment_size(sim, :wall_distance)
    out = Vector{Float64}(undef, length(poses))
    @inbounds for t in eachindex(poses)
        pose = _task_signal_first_pose(poses[t], :wall_distance)
        x = Float64(pose[1])
        y = Float64(pose[2])
        out[t] = min(x, size - x, y, size - y)
    end
    return out
end

"""
    heading_error(sim)

Compute the per-tick absolute wrapped gaze-to-stimulus angular error.
Requires the `:scene` channel.
"""
function heading_error(sim::SimResult)
    scenes = getchannel(sim.recorder, :scene)
    isempty(scenes) && throw(ArgumentError("heading_error needs :scene recorded; run simulate(...; record=(:rate, :scene))"))

    return [
        abs(_wrap_to_pi(
            _task_signal_field(scene, :theta, :heading_error) -
            _task_signal_field(scene, :phi, :heading_error),
        ))
        for scene in scenes
    ]
end

"""
    object_in_view(sim; threshold=0.5)

Per-tick indicator (`1.0`/`0.0`) of whether the tracked stimulus is currently
exciting the sensor bank — the strongest receptor activation on the tick is at or
above `threshold`. Requires the `:percepts` channel. Aligned to the `:rate` grid,
so it is directly usable as a `drive`/condition series for
`branching_ratio_mr_windowed` — i.e. "branching while the object is in view" vs
while the agent drifts without stimulus.

Task-agnostic in mechanism (any receptor task), but registered for `:tracking`,
where the receptors saturate to `1.0` within a few degrees of a sensor.
"""
function object_in_view(sim::SimResult; threshold::Real=0.5)
    raw = getchannel(sim.recorder, :percepts)
    isempty(raw) && throw(ArgumentError("object_in_view needs the :percepts channel recorded; run simulate(...; record=(:rate, :percepts))"))

    out = Vector{Float64}(undef, length(raw))
    @inbounds for t in eachindex(raw)
        vals = _analysis_numeric_vector(raw[t], :object_in_view, t)
        peak = isempty(vals) ? 0.0 : maximum(vals)
        out[t] = peak >= threshold ? 1.0 : 0.0
    end
    return out
end

"""
    ball_paddle_distance(sim)

Compute the per-tick absolute vertical distance between the ball and paddle.
Requires the `:scene` channel.
"""
function ball_paddle_distance(sim::SimResult)
    scenes = getchannel(sim.recorder, :scene)
    isempty(scenes) && throw(ArgumentError("ball_paddle_distance needs :scene recorded; run simulate(...; record=(:rate, :scene))"))

    return [
        abs(
            _task_signal_field(scene, :ball_y, :ball_paddle_distance) -
            _task_signal_field(scene, :paddle_y, :ball_paddle_distance),
        )
        for scene in scenes
    ]
end
