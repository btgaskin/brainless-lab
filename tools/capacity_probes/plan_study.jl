using BrainlessLab

"""Reuse the two fixed profiles and the exact two saved development nominees."""
function capacity_study_profiles()
    nominees = map((:compartmental_dense, :compartmental_structured)) do node
        path = joinpath("benchmarks", "ctrnn-readiness", "development", "$(node)-selection-plan.toml")
        source = first(first(read_plan(path).cases).conditions)
        ModelProfileSpec(Symbol(node, :_nominee_v1), node; n_nodes=200,
            parameters=source.composition.parameters, model=source.model,
            label="$(node) development nominee",
            mechanism="Saved compartmental CTRNN design; no new evolution or task-specific genome.",
            provenance=(path,), limitations=("Exploratory nominee, not confirmed benchmark evidence.",))
    end
    return (DIRECT_CONTROL_FALANDAYS_PROFILE, DIRECT_CONTROL_SORN_PROFILE, nominees...)
end

"""One declared starting cell per family; the full 64-cell library is opt-in."""
function capacity_study_cells()
    cells = capacity_probe_presets()
    ids = (:delayed_cue__delay_32, :recall_interference__delay_32_distractors_1,
        :delayed_xor__gap_32, :evidence_accumulation__pulses_32_evidence_250,
        :context_integration__pulses_32_evidence_250_conflicting_transient,
        :temporal_order__gap_8, :reversal_adaptation__single_reversal)
    return Tuple(only(c for c in cells if c.id === id) for id in ids)
end

"""Build planned ordinary operations. This function never runs simulations.

Starting gain 1 and trial counts are development proposals. Runtime preflight,
calibration, variance estimates and a new frozen protocol precede confirmation.
Pass `cells=capacity_probe_presets()` to generate the complete difficulty grid.
"""
function capacity_study_bundles(; cells=capacity_study_cells(), profiles=capacity_study_profiles())
    calibration, decoding = BrainlessLab.AbstractOperationPlan[], BrainlessLab.AbstractOperationPlan[]
    native_cases = BenchmarkCasePlan[]
    calibration_conditions, decoding_conditions = EvaluationTarget[], EvaluationTarget[]
    for (i, cell) in enumerate(cells)
        native_conditions = EvaluationTarget[]
        for profile in profiles
            id = Symbol(cell.id, :__, profile.id)
            composition = CompositionSpec(id, profile.node, cell.task;
                n_nodes=profile.n_nodes, parameters=copy(profile.parameters),
                task_options=deepcopy(cell.task_options), interface=InterfaceSpec(input_gain=1.0))
            development = EvaluationTarget(Symbol(id, :__calibration), composition,
                EvaluationSpec(blocks=16, horizon=cell.horizon, root_seed=1_700_000 + 10_000i);
                topology_key=profile.id, model=profile.model)
            push!(calibration_conditions, development)
            push!(calibration, SweepPlan(Symbol(id, :__gain), development;
                axes=(BrainlessLab.SweepAxis(:input_gain, DIRECT_CONTROL_GAIN_GRID; scope=:interface),)))
            push!(native_conditions, EvaluationTarget(Symbol(id, :__native_pilot), composition,
                EvaluationSpec(blocks=32, horizon=cell.horizon, root_seed=1_701_000 + 10_000i);
                topology_key=profile.id, model=profile.model))
            if cell.task !== :reversal_adaptation
                target = EvaluationTarget(Symbol(id, :__decoding), composition,
                    EvaluationSpec(blocks=4, trials_per_block=640, horizon=cell.horizon,
                        construction_scope=:block, reset=:full, root_seed=1_702_000 + 10_000i);
                    topology_key=profile.id, model=profile.model)
                push!(decoding_conditions, target)
                push!(decoding, ProfilePlan(target.id, target; analyses=(:probe_decodability,)))
            end
        end
        push!(native_cases, BenchmarkCasePlan(cell.id, Tuple(native_conditions);
            baseline=first(native_conditions).id))
    end
    pilot = BenchmarkPlan(:capacity_native_pilot, Tuple(native_cases))
    function bundle(id, question, conditions, operations)
        ExperimentSpec(id, v"1.0.0"; title=replace(string(id), '_' => ' '), question,
            conditions=Tuple(conditions), operations=Tuple(operations), evidence_state=:planned,
            limitations=(
                "Unexecuted development proposal. No confirmation seeds or core promotion are defined.",
                "Run a timed preflight before calibration; revise sample sizes from a variance pilot.",
                "Native gain 1 is provisional. Apply development selections in a new pilot protocol before comparison.",
                "Fixed 200-node profiles differ in connections, internal states and integration cost.",
                "Decoder accuracy is a separate readout diagnostic; no general capability claim follows."),
            metadata=(programme=:capacity_probes, stage=:development_proposal,
                n_nodes=200, core_membership=:candidate, no_cross_task_aggregate=true))
    end
    return (
        calibration=bundle(:capacity_calibration,
            "Which input gain should each fixed profile use on each declared probe cell?",
            calibration_conditions, calibration),
        native_pilot=bundle(:capacity_native_pilot,
            "How variable is native task performance across independent paired blocks?",
            (c for case in pilot.cases for c in case.conditions), (pilot,)),
        decoding=bundle(:capacity_decoding,
            "Is task information linearly recoverable from emitted activity of each fixed wiring?",
            decoding_conditions, decoding),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    destination = isempty(ARGS) ? mktempdir() : only(ARGS)
    for (name, experiment) in pairs(capacity_study_bundles())
        path = joinpath(destination, string(name))
        write_experiment(path, experiment)
        println(path)
    end
    println("Plans only. No simulations were executed.")
end
