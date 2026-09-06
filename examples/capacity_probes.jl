using BrainlessLab

"""Write small software checks for each new probe using ordinary operation records.

The random controller, eight nodes and two blocks are conformance settings.
They are not a model performance pilot or benchmark submission.
"""
function capacity_probe_smoke(; root=mktempdir())
    cases = BenchmarkCasePlan[]
    directories = String[]
    for (i, task) in enumerate(keys(BrainlessLab.CAPACITY_PROBE_DEFAULTS))
        composition = CompositionSpec(task, :null_random, task; n_nodes=8)
        target = EvaluationTarget(task, composition,
            EvaluationSpec(blocks=2, horizon=resolve_task(task).default_ticks, root_seed=1_610_000 + i))
        profile = ProfilePlan(Symbol(task, :__smoke), target; analyses=())
        record = run_operation(profile; root, id=string(profile.id))
        push!(directories, record.directory)
        push!(cases, BenchmarkCasePlan(task, (target,)))
    end
    benchmark = BenchmarkPlan(:capacity_probe_smoke, Tuple(cases))
    push!(directories, run_operation(benchmark; root, id="benchmark_smoke").directory)
    return directories
end

if abspath(PROGRAM_FILE) == @__FILE__
    root = isempty(ARGS) ? mktempdir() : only(ARGS)
    println("Software conformance records; no model comparison or core promotion:")
    foreach(println, capacity_probe_smoke(; root))
end
