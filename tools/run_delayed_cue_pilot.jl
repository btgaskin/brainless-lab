using BrainlessLab
using Statistics
using TOML

"""Run ordinary development sweeps and a fresh paired recall pilot.

Full records go beneath `records/`. The compact tables retain every development
block but are not confirmation records or accepted research contributions.
"""
function main(; root="records/delayed-cue-development",
    output="benchmarks/direct-control/v2/development")
    mkpath(output)
    profiles = (DIRECT_CONTROL_FALANDAYS_PROFILE, DIRECT_CONTROL_SORN_PROFILE)
    selections = Dict{String,Any}()
    sweep_rows = NamedTuple[]
    conditions = EvaluationTarget[]
    for profile in profiles
        composition = BrainlessLab._benchmark_composition(profile, :delayed_cue, 1.0)
        development = EvaluationTarget(Symbol(profile.id, :__cue_development), composition,
            EvaluationSpec(blocks=64, horizon=144, root_seed=942_001);
            topology_key=profile.id)
        plan = SweepPlan(Symbol(profile.id, :__cue_gain), development;
            axes=(BrainlessLab.SweepAxis(:input_gain, DIRECT_CONTROL_GAIN_GRID; scope=:interface),),
            max_rollouts=640)
        write_plan(joinpath(output, "$(profile.node)-gain-plan.toml"), plan)
        elapsed = @elapsed record = run_operation(plan; root)
        selection = select_input_gain(record.result)
        selections[String(profile.id)] = Dict("gain" => selection.gain,
            "development_accuracy" => selection.profile_value,
            "sweep_seconds" => elapsed,
            "record" => basename(record.directory))
        append!(sweep_rows, merge((profile=profile.id,), row)
            for row in BrainlessLab.tables(record.result).trials)
        push!(conditions, EvaluationTarget(Symbol(profile.id, :__cue_pilot),
            BrainlessLab._benchmark_composition(profile, :delayed_cue, selection.gain),
            EvaluationSpec(blocks=256, horizon=144, root_seed=943_001);
            topology_key=profile.id))
        println((profile=profile.id, gain=selection.gain,
            development_accuracy=selection.profile_value, seconds=elapsed))
    end
    pilot = BenchmarkPlan(:delayed_cue_performance_pilot,
        (BenchmarkCasePlan(:delayed_cue, Tuple(conditions); baseline=first(conditions).id),))
    write_plan(joinpath(output, "pilot-plan.toml"), pilot)
    elapsed = @elapsed record = run_operation(pilot; root)
    tables = BrainlessLab.tables(record.result)
    BrainlessLab._write_csv(joinpath(output, "gain-trials.csv"), sweep_rows)
    BrainlessLab._write_csv(joinpath(output, "pilot-trials.csv"), tables.trials)
    BrainlessLab._write_csv(joinpath(output, "pilot-statistics.csv"), tables.statistics)
    BrainlessLab._write_csv(joinpath(output, "pilot-contrasts.csv"), tables.contrasts)
    details = NamedTuple[]
    for group in record.result.batches, condition in group.conditions, trial in condition.batch.trials
        m = trial.simulation.metrics
        push!(details, (condition=trial.condition, block=trial.block, cue=m.cue,
            delay=m.delay, decision=m.decision, tied=m.tied, completed=m.completed,
            recall_accuracy=m.recall_accuracy))
    end
    BrainlessLab._write_csv(joinpath(output, "pilot-responses.csv"), details)
    open(joinpath(output, "selection.toml"), "w") do io
        TOML.print(io, Dict("evidence_state" => "tuned", "profiles" => selections,
            "pilot_seconds" => elapsed, "pilot_record" => basename(record.directory),
            "source_sha" => readchomp(`git rev-parse HEAD`),
            "source_state" => isempty(readchomp(`git status --porcelain`)) ? "clean" : "dirty"); sorted=true)
    end
    println(BrainlessLab.summary(record.result))
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
