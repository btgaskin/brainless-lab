Base.@kwdef struct FalandaysPaperTaskConfig
    task::Symbol
    nnodes::Int
    input_amp::Float64
    lrate_wmat::Float64
    lrate_targ::Float64
    sensory_noise::Float64 = 0.0
    sensory_noise_assumption::Bool = false
    clip_sensory_noise::Bool = true
    weight_init_mode::Symbol
    movement_amp::Float64 = 0.0
    arena::String = ""
    sensor_bank::String = ""
    source::String = ""
end

# Provenance: Falandays et al., `ReservoirModel_followups`, authors' Julia
# source at immutable upstream commit 81865f8784998104a5562abb548e018edf98a0e8:
# https://github.com/bfalandays/ReservoirModel_followups/tree/81865f8784998104a5562abb548e018edf98a0e8/Julia
# The authors define constants in each script; there is no shared parameter
# constructor. Line references below are to that commit.
#
# - Wall: `WallAvoidance/BraitenbergAgent.jl` lines 6-14 define node count,
#   link probability, leak, learning rates, target floor, movement gain, and
#   input gain. Lines 22, 25-33, 56-63, 83, and 94-96 define the noiseless
#   baseline, sensor bank and input wiring, weight initialisation, targets, and
#   arena. `BraitenbergAgent_Functions.jl` lines 132-143 and 149-186 define the
#   sensor values, threshold multiplier, and learning updates.
# - Tracking: `ObjectTracking/RotatingAgent.jl` lines 7-17, 23-32, 55-62,
#   82, and 93-95 define the constants, 62-channel bank, wiring and weights,
#   targets, and arena. `RotatingAgent_Functions.jl` lines 59-60, 93-100, and
#   105-142 define its Gaussian-tuned input, threshold, and learning updates.
# - Pong: `Pong/PongAgent.jl` lines 11-21, 30-38, 62-71, 93, and 104-106
#   define the constants, 46-channel bank, wiring and mixed weights, targets,
#   and arena. `PongAgent_Functions.jl` lines 132-145 and 161-198 define its
#   sparse binary input, threshold, and learning updates.
# - Collective: `MultipleAgents/MultipleAgents.jl` lines 20-33, 36-58, and
#   69-75 define the sensor bank, node and learning constants, small-world
#   mode, noise, 15x15 periodic arena, and `input_amp = 250 * 0.1 / 2 = 12.5`.
#   `movement_amp=0.0` is an inapplicable-field sentinel in this table; the
#   source uses separate speed and heading-rate parameters on lines 49-53.
#
# Tracking and Pong do not add a sensory-noise term, so their table value 0.0
# records its absence. `clip_sensory_noise` and `sensory_noise_assumption` are
# BrainlessLab provenance fields, not constants from the authors' scripts.
#
# The scientific reference is Falandays, Yoshimi, Warren, and Spivey (2024),
# "A potential mechanism for Gibsonian resonance", Cognitive Neurodynamics
# 18(4), 1811-1834: https://doi.org/10.1007/s11571-023-09988-2
# The single-agent `lrate_wmat=1.0` is also author-confirmed in upstream commit
# ba56475: https://github.com/bfalandays/ReservoirModel_followups/commit/ba56475
#
# Input-gain interpretation (our inference, not a claim by the authors): the
# scripts appear to hand-normalise input for the number of simultaneously
# active sensors. Expected drive per node scales approximately as
# `n_active * p_link * input_amp`. Wall has two continuously graded sensors;
# tracking has 62 Gaussian-tuned channels with only a small active subset; Pong
# has 46 channels with at most one binary channel active. The gains therefore
# offset dense versus sparse activity and keep drive on a comparable order
# despite very different bank widths. The source does not state this rationale.
const FALANDAYS_PAPER_CONFIG = Dict{Symbol,FalandaysPaperTaskConfig}(
    :wall => FalandaysPaperTaskConfig(
        task=:wall,
        nnodes=200,
        input_amp=4.0,
        lrate_wmat=1.0,
        lrate_targ=0.01,
        # `BraitenbergAgent.jl` hardcodes `global noise = 0`; the base-condition
        # figures (`Figs/hits_base.pdf`, `spikes_base.pdf`, ...) are noiseless,
        # with noise a separately labeled experimental condition
        # (`hits_noise.pdf`, `spikes_noise.pdf`) rather than the baseline. The
        # previous 0.1 default here was an unconfirmed assumption; reverted to
        # the source's noiseless baseline.
        sensory_noise=0.0,
        weight_init_mode=:excitatory,
        movement_amp=10.0,
        arena="15x15 non-periodic box",
        sensor_bank="2 wall ray sensors at +/-45 degrees",
        source="WallAvoidance/BraitenbergAgent.jl",
    ),
    :tracking => FalandaysPaperTaskConfig(
        task=:tracking,
        nnodes=200,
        input_amp=0.75,
        lrate_wmat=1.0,
        lrate_targ=0.01,
        sensory_noise=0.0,
        weight_init_mode=:excitatory,
        movement_amp=10.0,
        arena="3x3 periodic object-tracking arena",
        sensor_bank="62 angular sensors: two 31-sensor banks over -60:4:60 with +/-30 degree eye offsets",
        source="ObjectTracking/RotatingAgent.jl",
    ),
    :pong => FalandaysPaperTaskConfig(
        task=:pong,
        nnodes=500,
        input_amp=2.75,
        lrate_wmat=1.0,
        lrate_targ=0.1,
        sensory_noise=0.0,
        weight_init_mode=:pong_mixed,
        movement_amp=100.0,
        arena="1000x500 non-periodic pong arena",
        sensor_bank="46 binary bearing sensors over -90:4:90 degrees",
        source="Pong/PongAgent.jl",
    ),
    :collective => FalandaysPaperTaskConfig(
        task=:collective,
        nnodes=250,
        input_amp=12.5,
        lrate_wmat=0.10,
        lrate_targ=0.01,
        sensory_noise=0.1,
        weight_init_mode=:collective_dale_smallworld,
        movement_amp=0.0,
        arena="15x15 periodic torus",
        sensor_bank="64 receptors: two reserved channels plus 62 bearing sensors",
        source="MultipleAgents/MultipleAgents.jl",
    ),
)

function falandays_paper_config(task::Union{Symbol,AbstractString})
    sym = Symbol(task)
    haskey(FALANDAYS_PAPER_CONFIG, sym) ||
        throw(KeyError("no Falandays paper config for task :$(sym)"))
    return FALANDAYS_PAPER_CONFIG[sym]
end
