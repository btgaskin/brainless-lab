# Two-hemisphere ("split-brain") composite node with CONTRALATERAL wiring.
#
# Sensors and effectors are each split into a left block (first half) and a right
# block (second half). Two independent half-size reservoirs cross over:
#   hemi_a:  RIGHT sensors -> LEFT  effectors
#   hemi_b:  LEFT  sensors -> RIGHT effectors
# Each hemisphere is its own FalandaysReservoir of ~N/2 nodes; there is no
# coupling between them except through the shared body/world.

mutable struct HemisphericReservoir{A<:Reservoir,B<:Reservoir} <: Reservoir
    hemi_a::A              # right sensors -> left effectors
    hemi_b::B              # left sensors  -> right effectors
    n_receptors::Int
    n_effectors::Int
    n_left_sensors::Int    # sensors[1:n_left_sensors] = left;  rest = right
    n_left_effectors::Int  # effectors[1:n_left_effectors] = left; rest = right
    na::Int                # node count of hemi_a (split point for combined spikes)
end

function step!(r::HemisphericReservoir, receptors)
    rc = _float_vector(receptors, "receptors")
    length(rc) == r.n_receptors ||
        throw(DimensionMismatch("expected $(r.n_receptors) receptors, got $(length(rc))"))
    left_sens = rc[1:r.n_left_sensors]
    right_sens = rc[(r.n_left_sensors + 1):end]
    sa = step!(r.hemi_a, right_sens)   # right -> left hemisphere
    sb = step!(r.hemi_b, left_sens)    # left  -> right hemisphere
    return vcat(sa, sb)
end

function effectors(r::HemisphericReservoir, spikes)
    s = _float_vector(spikes, "spikes")
    sa = s[1:r.na]
    sb = s[(r.na + 1):end]
    ea = effectors(r.hemi_a, sa)       # -> left effectors
    eb = effectors(r.hemi_b, sb)       # -> right effectors
    return vcat(ea, eb)                # [left; right] in effector order
end

n_receptors(r::HemisphericReservoir) = r.n_receptors
n_effectors(r::HemisphericReservoir) = r.n_effectors

function reset!(r::HemisphericReservoir)
    reset!(r.hemi_a)
    reset!(r.hemi_b)
    return r
end

snapshot_state(r::HemisphericReservoir) =
    (a=snapshot_state(r.hemi_a), b=snapshot_state(r.hemi_b))

function load_state!(r::HemisphericReservoir, state)
    load_state!(r.hemi_a, state.a)
    load_state!(r.hemi_b, state.b)
    return r
end
