using BrainlessLab
using BrainlessLab: SweepAxis

function build_study(destination=joinpath(@__DIR__, "pilot"))
    base = composition_spec(DEFAULT_REGISTRY, :falandays_tracking)
    evaluation = EvaluationSpec(
        blocks=4, trials_per_block=1, horizon=4000, warmup=2000,
        construction_scope=:trial, reset=:full, root_seed=2026091401,
    )
    conditions = EvaluationTarget[]
    operations = BrainlessLab.AbstractOperationPlan[]
    regimes = (
        (:continuous, ()),
        (:weights_frozen_start, (ScheduledIntervention(1, :freeze_weights),)),
        (:all_frozen_start, (ScheduledIntervention(1, :freeze_plasticity),)),
        (:weights_frozen_late, (ScheduledIntervention(2001, :freeze_weights),)),
        (:all_frozen_late, (ScheduledIntervention(2001, :freeze_plasticity),)),
    )
    for (name, interventions) in regimes
        target = EvaluationTarget(name, base, evaluation; interventions)
        push!(conditions, target)
        push!(operations, SweepPlan(Symbol(:scale_, name), target;
            axes=(SweepAxis(:recurrent_init_scale, (0.01, 0.1, 1.0)),),
            max_rollouts=12))
    end
    for scale in (0.1, 1.0), (regime, interventions) in regimes
        regime in (:continuous, :weights_frozen_late, :all_frozen_late) || continue
        name = Symbol(:profile_, regime, scale == 0.1 ? :_small : :_reference)
        parameters = merge(base.parameters, Dict(:recurrent_init_scale => scale))
        composition = CompositionSpec(name, base.node, base.task;
            n_nodes=base.n_nodes, n_agents=base.n_agents, body=base.body,
            parameters, task_options=base.task_options, body_options=base.body_options,
            interface=base.interface, interaction_cycle=base.interaction_cycle)
        target = EvaluationTarget(name, composition, evaluation; interventions)
        push!(conditions, target)
        push!(operations, ProfilePlan(name, target;
            analyses=(:tracking_plasticity_diagnostics, :node_target_error),
            analysis_options=Dict(:tracking_plasticity_diagnostics =>
                (window=400, stride=200, kmax=20, min_r2=0.0, heading_bins=18)),
            compute_every=Dict(:spectral_radius => 200)))
    end
    experiment = ExperimentSpec(:initialisation_adaptation, v"1.0.0";
        title="Initial recurrent scale and continued homeostatic adaptation",
        question="Does recurrent initialisation scale alter the benefit of weight and target adaptation in canonical Tracking?",
        conditions=Tuple(conditions), operations=Tuple(operations), evidence_state=:planned,
        limitations=(
            "Four development blocks estimate feasibility and describe cases; they do not support confirmation or equivalence claims.",
            "The task, horizon and initialisation distribution are BrainlessLab choices, not a replication of Marc's unspecified protocol.",
            "The scored interval is ticks 2001 through 4000 for every condition; early acquisition is not the primary endpoint.",
            "Profiles reuse sweep seeds and are diagnostics of the same blocks, not independent replication.",
            "Branching estimates and spectral radius do not establish criticality or a causal mechanism.",
        ),
        metadata=(stage=:development_pilot, scales=(0.01, 0.1, 1.0),
                  independent_unit=:block, freeze_tick=2001))
    write_experiment(destination, experiment)
end

if abspath(PROGRAM_FILE) == @__FILE__
    build_study()
end
