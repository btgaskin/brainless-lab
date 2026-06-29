"""
    rasterplot(args...; kwargs...)

Generic spike-raster visualization hook. Concrete plotting methods live in
package extensions so visualization dependencies stay off the compute path.
"""
function rasterplot end

"""
    rateplot(args...; kwargs...)

Generic firing-rate visualization hook.
"""
function rateplot end

"""
    trajectoryplot(args...; kwargs...)

Generic agent-trajectory visualization hook.
"""
function trajectoryplot end

"""
    swarmplot(args...; kwargs...)

Generic swarm-state visualization hook.
"""
function swarmplot end

"""
    networkplot(args...; kwargs...)

Generic reservoir-network visualization hook.
"""
function networkplot end

"""
    driftplot(args...; kwargs...)

Generic representational-drift visualization hook.
"""
function driftplot end

"""
    fitnessplot(args...; kwargs...)

Generic development-curve visualization hook.
"""
function fitnessplot end

"""
    visualize(args...; kwargs...)

Generic multi-panel visualization hook.
"""
function visualize end

"""
    explore(args...; kwargs...)

Generic interactive exploration hook.
"""
function explore end

"""
    replay(args...; kwargs...)

Generic recorded-run replay hook.
"""
function replay end
