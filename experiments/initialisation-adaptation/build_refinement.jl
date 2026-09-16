using BrainlessLab
using BrainlessLab: experiment_branch

"""Author the fresh-seed scale refinement without executing simulations."""
function build_refinement(destination=joinpath(@__DIR__, "refinement-v1"))
    scales = (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0)
    regimes = ((:both_on, true, true), (:weights_off, false, true),
               (:targets_off, true, false), (:both_off, false, false))
    source = read_experiment(joinpath(@__DIR__, "programme"))
    children = ExperimentSpec[]
    for task in (:tracking, :pong)
        original = experiment_branch(source, "reproduction/" * String(task))
        base = first(original.conditions).composition
        evaluation = EvaluationSpec(blocks=10, trials_per_block=1,
            horizon=first(original.conditions).evaluation.horizon, warmup=0,
            root_seed=2026091801, construction_scope=:trial, reset=:full)
        conditions = EvaluationTarget[]
        cases = BenchmarkCasePlan[]
        for (i, scale) in enumerate(scales)
            group = EvaluationTarget[]
            for (regime, weights, targets) in regimes
                id = Symbol(task, :_s, i, :_, regime)
                parameters = merge(base.parameters, Dict(:recurrent_init_scale=>scale))
                weights || (parameters[:lrate_wmat] = 0.0)
                targets || (parameters[:lrate_targ] = 0.0)
                composition = CompositionSpec(id, base.node, base.task;
                    n_nodes=base.n_nodes, body=base.body, parameters,
                    task_options=base.task_options, body_options=base.body_options,
                    interface=base.interface, interaction_cycle=base.interaction_cycle)
                push!(group, EvaluationTarget(id, composition, evaluation))
            end
            append!(conditions, group)
            push!(cases, BenchmarkCasePlan(Symbol(:scale_, i), Tuple(group);
                baseline=first(group).id))
        end
        push!(children, ExperimentSpec(task, v"1.0.0";
            title="$(uppercasefirst(String(task))): finer scale grid",
            question="How does the advantage or disadvantage of frozen weights vary between recurrent scales 0.01 and 1.0?",
            description="Evaluate seven scales with ten independent paired blocks per scale and update policy. Start from tick 1 with no discarded warm-up. Retain both endpoints and all four weight/target update policies.",
            conditions=Tuple(conditions),
            operations=(BenchmarkPlan(Symbol(task, :_comparison), Tuple(cases)),),
            evidence_state=:exploratory,
            objectives=("Describe the scale-response curve and paired weights-off minus both-on contrasts without selecting a winning cell as confirmation.",),
            metadata=(scales=scales, independent_unit=:block,
                predecessor_experiment="initialisation_adaptation/reproduction/$(task)",
                predecessor_version="1.0.0", predecessor_root_seed=2026091701),
            limitations=("This grid was chosen after inspecting the first four-block study; it is exploratory, not sealed confirmation.",
                "Ten fresh development blocks per condition are not a power calculation or an equivalence test. Pointwise intervals are unadjusted for multiple comparisons.",
                "Do not pool these results with the predecessor run. Paired seeds are shared across scales and policies within each task.",
                "The primary contrast retains target adaptation; full freezing and targets-off are supporting controls, not independent causal contributions.",
                "Marc's exact settings are unknown. Raw task outcomes remain primary; anchor-relative scores may be clipped.")))
    end
    root = ExperimentSpec(:initialisation_scale_refinement, v"1.0.0";
        title="Initialisation scale: Tracking and Pong refinement",
        question="Does a finer initialisation grid reproduce the scale-dependent pattern in the first Tracking and Pong runs?",
        description="Follow the initial 96-trial study with 560 fresh trials: seven scales, four update policies and ten independent blocks on each task. Preserve the first study separately; this follow-up was requested after its results were inspected.",
        evidence_state=:exploratory, children=Tuple(children),
        metadata=(predecessor_experiment="initialisation_adaptation", predecessor_version="1.0.0"),
        limitations=("This is a development follow-up, not an exact replication of Marc's implementation or a confirmed optimum.",
            "Task outcomes have different meanings; no cross-task aggregate is defined."))
    write_experiment(destination, root)
    return destination
end

if abspath(PROGRAM_FILE) == @__FILE__
    println(build_refinement())
end
