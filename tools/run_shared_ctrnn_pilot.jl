using BrainlessLab, Random, Statistics, TOML

const CTRNN_PILOT_PARAMETERS = Dict{Symbol,Any}(:dt => 1.0, :substeps => 5,
    :link_p => 0.1, :rho => 0.2, :init_random => true, :state_scale => 0.05)

function pilot_baselines(spec, targets)
    rows = NamedTuple[]
    scores = Dict{Symbol,Float64}()
    for (protocol, target) in zip(spec.task_protocols, targets)
        values = Float64[]
        for profile in spec.profiles
            entry = only(entry for entry in spec.entries if entry.task === protocol.task && entry.profile === profile.id)
            baseline = EvaluationTarget(Symbol(protocol.task, :__, profile.id, :__pilot_baseline),
                BrainlessLab._benchmark_composition(profile, protocol.task, entry.input_gain),
                target.evaluation; topology_key=profile.id)
            batch = evaluate(baseline)
            append!(rows, BrainlessLab.trial_table(batch))
            push!(values, mean(BrainlessLab._evolution_trial_value(trial, :benchmark_profile) for trial in batch.trials))
        end
        scores[protocol.task] = maximum(values)
    end
    return rows, scores
end

"""Six small shared-design searches, followed by fresh development selection blocks.

The same genome, node count, integration policy, and input gain serve every task.
The wall-time cap is checked between episodes; a running episode may finish after it.
No confirmation protocol is executed by this script.
"""
function main(; root="records/shared-ctrnn-pilot", output="benchmarks/ctrnn-readiness/development",
    max_seconds=7200.0)
    mkpath(output)
    started = time_ns()
    remaining() = max_seconds - (time_ns() - started) / 1e9
    spec = DIRECT_CONTROL_BENCHMARK_V2
    initialisation = TOML.parsefile(joinpath(output, "initialisation.toml"))["nodes"]
    trial_rows = NamedTuple[]
    score_rows = NamedTuple[]
    seed_rows = NamedTuple[]
    nominations = Dict{String,Any}()
    task_ids = getfield.(spec.task_protocols, :task)
    template = benchmark_evolution_targets(spec, :compartmental_structured;
        root_seed=961_000, blocks=2, parameters=CTRNN_PILOT_PARAMETERS)
    baseline_rows, baseline_scores = pilot_baselines(spec, template)
    BrainlessLab._write_csv(joinpath(output, "baseline-trials.csv"), baseline_rows)
    for node in (:compartmental_structured, :compartmental_dense)
        scale = initialisation[String(node)]["scale"]
        targets = benchmark_evolution_targets(spec, node;
            root_seed=961_000, blocks=2, parameters=CTRNN_PILOT_PARAMETERS)
        candidates = NamedTuple[]
        for search_seed in (971_001, 971_002, 971_003)
            remaining() > 0 || break
            run = BrainlessLab.Evolution.RunConfig(strategy=:nsga2, iterations=2,
                search_seed, measure=:benchmark_profile, direction=:maximise,
                initialisation=BrainlessLab.Evolution.NormalInitialisation(centre=:zero, scale=scale),
                options=(population=4,))
            plan = EvolutionPlan(Symbol(node, :__, search_seed), targets; run)
            write_plan(joinpath(output, "$(node)-$(search_seed)-plan.toml"), plan)
            resolved = resolve(plan, DEFAULT_REGISTRY)
            if search_seed == 971_001
                model = BrainlessLab.Evolution.decode(resolved.design,
                    scale .* randn(MersenneTwister(970_001), resolved.design.dimension))
                seconds = @elapsed for (target, composition) in zip(targets, resolved.targets)
                    BrainlessLab._evaluate_evolution_target(target, model, :benchmark_profile,
                        DEFAULT_REGISTRY, composition)
                end
                estimate = 24 * seconds
                println((; node, seconds_per_candidate=seconds, estimated_family_seconds=estimate, remaining_seconds=remaining()))
                open(joinpath(output, "$(node)-cost-estimate.toml"), "w") do io
                    TOML.print(io, Dict("seconds_per_candidate" => seconds, "estimated_search_seconds" => estimate,
                        "budget_remaining_seconds" => remaining()))
                end
            end
            record = try
                run_operation(plan; root, max_seconds=max(remaining(), 0.001))
            catch error
                error isa BrainlessLab.EvolutionBudgetExceeded || rethrow()
                println((; node, search_seed, status=:budget_exhausted))
                break
            end
            tables = BrainlessLab.tables(record.result)
            context = (; node, search_seed, record=basename(record.directory))
            append!(trial_rows, merge(context, row) for row in tables.candidate_trials)
            append!(score_rows, merge(context, row) for row in tables.candidate_scores)
            append!(seed_rows, merge(context, row) for row in BrainlessLab._evolution_seed_rows(record.result.candidates))
            for candidate in record.result.candidates
                candidate.valid || continue
                scores = Float64.(BrainlessLab._candidate_scores(candidate))
                margins = [(score - baseline_scores[task]) / max(abs(baseline_scores[task]), 1.0)
                    for (task, score) in zip(task_ids, scores)]
                push!(candidates, (; candidate, scores, margins, search_seed, record=basename(record.directory)))
            end
            BrainlessLab._write_csv(joinpath(output, "candidate-trials.csv"), trial_rows)
            BrainlessLab._write_csv(joinpath(output, "candidate-scores.csv"), score_rows)
            BrainlessLab._write_csv(joinpath(output, "candidate-seeds.csv"), seed_rows)
            println((; node, search_seed, status=:complete, valid=count(c -> c.valid, record.result.candidates)))
        end
        isempty(candidates) && continue
        chosen = first(sort(candidates; by=row -> (-minimum(row.margins), -mean(row.margins),
            row.search_seed, row.candidate.iteration, row.candidate.id)))
        design = BrainlessLab.node_spec(DEFAULT_REGISTRY, node).design
        model = BrainlessLab.Evolution.decode(design, chosen.candidate.coordinates)
        reference = only(BrainlessLab.Evolution.write_models(joinpath(output, "$(node)-nominee"), node, design,
            ((model_id="selected", role="development_nominee", model=model),)))
        nominations[String(node)] = Dict("source_record" => chosen.record,
            "search_seed" => chosen.search_seed, "iteration" => chosen.candidate.iteration,
            "candidate" => chosen.candidate.id, "model_path" => reference.path,
            "scores" => chosen.scores, "baseline_relative_margins" => chosen.margins,
            "selection_status" => "pending")
        if remaining() > 0
            fresh = benchmark_evolution_targets(spec, node; root_seed=981_000, blocks=8,
                parameters=CTRNN_PILOT_PARAMETERS)
            cases = Tuple(BrainlessLab.BenchmarkCasePlan(protocol.task,
                (EvaluationTarget(target.id, target.composition, target.evaluation;
                    topology_key=node, model=reference),)) for (protocol, target) in zip(spec.task_protocols, fresh))
            selection = BenchmarkPlan(Symbol(node, :__fresh_selection), cases)
            write_plan(joinpath(output, "$(node)-selection-plan.toml"), selection)
            # Keep the same explicit episode budget for this later evaluation.
            try
                result = execute(resolve(selection, DEFAULT_REGISTRY);
                    check_budget=() -> remaining() > 0 ? nothing : throw(BrainlessLab.EvolutionBudgetExceeded()))
                directory = write_record(selection, result; root)
                selection_tables = BrainlessLab.tables(result)
                BrainlessLab._write_csv(joinpath(output, "$(node)-selection-trials.csv"), selection_tables.trials)
                BrainlessLab._write_csv(joinpath(output, "$(node)-selection-statistics.csv"), selection_tables.statistics)
                nominations[String(node)]["selection_status"] = "complete"
                nominations[String(node)]["selection_record"] = basename(directory)
            catch error
                error isa BrainlessLab.EvolutionBudgetExceeded || rethrow()
                nominations[String(node)]["selection_status"] = "budget_exhausted"
            end
        end
        open(joinpath(output, "nominations.toml"), "w") do io
            TOML.print(io, Dict("evidence_state" => "tuned", "nodes" => nominations,
                "elapsed_seconds" => (time_ns() - started) / 1e9, "budget_seconds" => max_seconds,
                "source_sha" => readchomp(`git rev-parse HEAD`)); sorted=true)
        end
    end
    return nominations
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
