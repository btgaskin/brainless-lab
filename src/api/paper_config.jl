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

# Every numeric constant below was checked directly against the original
# Falandays et al. Julia source (`resources/ReservoirModel_followups/Julia/`
# in the neural-cognition workspace, sibling to this repo) -- not against the
# in-house v0.2 numpy reimplementation, which has since been found to disagree
# with the authors' code in at least one place (its `wall` input weight is
# 2.0; the authors' `BraitenbergAgent.jl` sets `input_amp = 4`, matching this
# table). `lrate_wmat = 1.0` for the single-agent tasks is author-confirmed,
# not just source-read: see commit ba56475 in that repo ("Corrected a
# misleading declaration of the learning rate for weights" -- Ben Falandays,
# 2023-03-08), which fixes an earlier .01 that "was actually not being
# applied" to the true effective rate of 1.0.
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
