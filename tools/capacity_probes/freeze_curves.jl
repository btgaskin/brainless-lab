using BrainlessLab
include(joinpath(@__DIR__, "plan_study.jl"))

"""Author ordinary benchmark branches for a within-episode freeze-time curve.

The skill edits keyword arguments, not a second protocol schema. `cells` accepts the
seven starting cells or all `capacity_probe_presets()`. No simulations run here.
"""
function capacity_freeze_programme(; cells=capacity_study_cells(), scales=(0.1,),
    blocks=10, trials_per_block=16, root_seed=2026092201, input_gain=1.0,
    fractions=(0.0, 0.25, 0.5, 0.75, 1.0), cutoffs=Dict{Symbol,Vector{Int}}(),
    mechanisms=(:freeze_weights, :freeze_plasticity), version=v"1.0.0")
    blocks > 0 && trials_per_block > 0 || throw(ArgumentError("positive repetition counts required"))
    !isempty(scales) && all(s -> isfinite(s) && s > 0, scales) && allunique(scales) ||
        throw(ArgumentError("scales must be unique positive finite values"))
    !isempty(mechanisms) && allunique(mechanisms) &&
        all(m -> m in (:freeze_weights, :freeze_plasticity), mechanisms) ||
        throw(ArgumentError("choose weight-only or complete freezing"))
    !isempty(fractions) && all(f -> isfinite(f) && 0 <= f <= 1, fractions) ||
        throw(ArgumentError("cutoff fractions must lie in [0,1]"))
    allunique(getfield.(cells, :id)) || throw(ArgumentError("duplicate cells"))
    all(k -> k in getfield.(cells, :id), keys(cutoffs)) || throw(ArgumentError("unknown cutoff cell"))
    profile = DIRECT_CONTROL_FALANDAYS_PROFILE
    library = capacity_probe_presets()
    branches = ExperimentSpec[]
    for cell in cells
        index = findfirst(c -> c.id == cell.id, library)
        index === nothing && throw(ArgumentError("unknown capacity cell $(cell.id)"))
        options = deepcopy(cell.task_options)
        reversal = cell.task === :reversal_adaptation
        # Fix event timing in this separately declared cell to align cuts across blocks.
        if reversal
            options[:reversal_range] = (48, 48)
        end
        response_start = cell.horizon - options[:response_ticks]
        round_ticks = reversal ? options[:cue_ticks]+options[:response_ticks]+options[:feedback_ticks] : 1
        last_cut = reversal ? 62round_ticks : response_start
        defaults = reversal ? [0, 24round_ticks, 47round_ticks, 48round_ticks, 52round_ticks, 56round_ticks, 62round_ticks] :
            round.(Int, collect(fractions) .* last_cut)
        ns = sort!(unique!(Int[0; get(cutoffs, cell.id, defaults)]))
        all(n -> 0 <= n <= last_cut, ns) || throw(ArgumentError(
            "cutoffs must precede completion of the scored response for $(cell.id)"))
        reversal && any(n -> n % round_ticks != 0, ns) && throw(ArgumentError("reversal cuts must align with round boundaries"))
        conditions = EvaluationTarget[]
        cases = BenchmarkCasePlan[]
        for (i, scale) in enumerate(scales)
            evaluation = EvaluationSpec(; blocks, trials_per_block=reversal ? 1 : trials_per_block,
                horizon=cell.horizon, warmup=0, root_seed=root_seed+10_000index,
                construction_scope=:block, reset=:full)
            function target(id, interventions)
                composition = CompositionSpec(id, profile.node, cell.task; n_nodes=profile.n_nodes,
                    parameters=merge(profile.parameters, Dict(:recurrent_init_scale=>Float64(scale))),
                    task_options=options, interface=InterfaceSpec(; input_gain))
                EvaluationTarget(id, composition, evaluation; topology_key=profile.id, interventions)
            end
            baseline = target(Symbol(:s, i, :_continuous), ())
            group = EvaluationTarget[baseline]
            for mechanism in mechanisms, n in ns
                push!(group, target(Symbol(:s, i, :_, mechanism, :_after_, n),
                    (ScheduledIntervention(n+1, mechanism),)))
            end
            append!(conditions, group)
            push!(cases, BenchmarkCasePlan(Symbol(:scale_, i), Tuple(group); baseline=baseline.id))
        end
        push!(branches, ExperimentSpec(cell.id, version;
            title=replace(String(cell.id), "__"=>": ", "_"=>" "),
            question="How does the native task outcome change when plasticity stops after n adaptive ticks?",
            description=reversal ?
                "Fixed reversal at round 48. Cut plasticity at shared round boundaries and score the task's first 16 post-reversal rounds. This is a declared timing variation of the random-reversal probe." :
                "Start each episode from a full reset, freeze after n completed ticks and score the same final response. Wiring is paired within independent blocks; experience does not accumulate across episodes.",
            conditions=Tuple(conditions), operations=(BenchmarkPlan(:freeze_curve, Tuple(cases)),),
            evidence_state=:exploratory,
            metadata=(scales=Tuple(scales), adaptive_ticks=Tuple(ns),
                independent_unit=:wiring_block, analysis=:adjacent_paired_slopes,
                refinement=:midpoint_of_steepest_observed_interval,
                fixed_reversal_round=reversal ? 48 : 0,
                within_episode=true, parent_cell=String(cell.id)),
            limitations=("Native task performance is not decoder accuracy or evidence of learning across episodes.",
                "A flat or near-chance curve does not establish a useful knee. Slopes are finite differences in raw score per adaptive tick.",
                "Maximum absolute slope selects an observed interval, not a unique knee; retain ties and direction, and refine with new explicit cutoffs.",
                "Input gain and the fixed Falandays direct-control profile are exploratory choices. No cross-task aggregate is defined.",
                "Always-on is a reference line, not an extra finite cutoff or derivative endpoint.")))
    end
    return ExperimentSpec(:capacity_freeze_curves, version;
        title="When does plasticity matter within a capacity probe?",
        question="How do freeze-time curves differ across capacity probes?",
        description="Skill-operated exploration: editable repetitions, cells, scales and cutoffs; ordinary experiment records; curve and paired finite-difference analysis. No sealed set or mandatory hypothesis.",
        children=Tuple(branches), evidence_state=:exploratory,
        limitations=("This protocol covers native within-episode performance. Cross-episode preparation and decoder readouts are different studies.",))
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS)==1 || error("usage: julia --project=. tools/capacity_probes/freeze_curves.jl NEW-PROTOCOL-DIRECTORY")
    write_experiment(only(ARGS), capacity_freeze_programme())
    println("Authored seven capacity families; no simulations executed.")
end
