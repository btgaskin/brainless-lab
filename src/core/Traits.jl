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
