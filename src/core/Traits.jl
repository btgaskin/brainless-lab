"""
    PlasticityTrait

Holy-trait supertype for declaring reservoir plasticity behavior.
"""
abstract type PlasticityTrait end

abstract type SpatialTrait end
struct Aspatial <: SpatialTrait end
struct Embedded{D} <: SpatialTrait end

abstract type DelayTrait end
struct UnitDelay <: DelayTrait end
struct HeteroDelay <: DelayTrait end

"""
    NoPlasticity

Trait value for reservoirs whose parameters are fixed during a rollout.
"""
struct NoPlasticity <: PlasticityTrait end

"""
    OnlinePlasticity

Trait value for reservoirs that can adapt during a rollout.
"""
struct OnlinePlasticity <: PlasticityTrait end

"""
    plasticity(reservoir)

Return the reservoir plasticity trait.

The default is `NoPlasticity()`. Concrete reservoir families can specialize this
method to declare online adaptation or future plasticity modes.
"""
plasticity(::Reservoir) = NoPlasticity()

"""
    WindowTrait

Holy-trait supertype for how a reservoir is clocked against the world within a
single environment step — the temporal-averaging window (see the timing knobs in
the receptors/effectors docs).
"""
abstract type WindowTrait end

"""
    IntrinsicWindow

The node owns its own temporal complexity internally and integrates a whole
env-step window inside a single `step!` — e.g. forward-Euler sub-integration
(`CompartmentalReservoir`'s `substeps`), or, in principle, a real-hardware
round-trip. The framework calls `step!` once and must NOT loop it.
"""
struct IntrinsicWindow <: WindowTrait end

"""
    SteppedWindow

The node is a single-tick map; the framework runs `step!` `temporal_window`
times per env step, holding the afferent, and mean-reduces the outputs. At
`temporal_window == 1` this is exactly one bare `step!` — today's behavior.
"""
struct SteppedWindow <: WindowTrait end

"""
    windowing(reservoir)

Return the reservoir temporal-window trait. Default `SteppedWindow()`; a node
that integrates its own sub-step window specializes this to `IntrinsicWindow()`.
"""
windowing(::Reservoir) = SteppedWindow()

"""
    temporal_window(reservoir)

Number of reservoir ticks per environment step (the window `K`). Default `1`
(one tick per env step). Nodes with a sub-step knob return it here.
"""
temporal_window(::Reservoir)::Int = 1
