#!/usr/bin/env julia

# Re-exec with a higher thread count so independent rollouts spread across
# cores. Unlike the other entry scripts' `-t auto` (measured only 4 threads on
# this 10-core box), default to a fixed floor of 8 -- override with
# BRAINLESSLAB_THREADS, or pin JULIA_NUM_THREADS yourself to skip this.
if Threads.nthreads() == 1 &&
   !haskey(ENV, "JULIA_NUM_THREADS") &&
   get(ENV, "BRAINLESSLAB_AUTOTHREADS", "1") != "0"
    n = get(ENV, "BRAINLESSLAB_THREADS", "8")
    _cmd = addenv(
        `$(Base.julia_cmd()) --threads=$(n) --project=$(Base.active_project()) $(abspath(PROGRAM_FILE)) $(ARGS)`,
        "BRAINLESSLAB_AUTOTHREADS" => "0",
    )
    _proc = run(ignorestatus(_cmd))
    exit(_proc.exitcode)
end

# NSGA-II training driver: evolves compartmental_structured jointly across all 5
# core tasks as separate objectives (no :min/:mean scalarization), then saves the
# highest-mean-objective Pareto-front member as the genome for the
# :compartmental_structured_nsga bench roster alias (same genome copied into every
# task cell, since it's one generalist genome, not five specialists).

include("Benchmark.jl")
using .Benchmark
using BrainlessLab

const TASKS = (:wall, :tracking, :pong, :cartpole, :cartpole_swingup)

function main()
    t0 = time()
    out = BrainlessLab.nsga2(
        model_sym=:compartmental_structured,
        train_tasks=TASKS,
        popsize=32,
        generations=30,
        k_trials=4,
        N=200,
        ticks=300,
        seed=0,
    )
    elapsed = time() - t0

    println("n_evaluated=", out.n_evaluated, "  elapsed_s=", round(elapsed; digits=1))
    println("pareto_front size=", length(out.pareto_front))
    for (i, task) in enumerate(TASKS)
        vals = [p.objectives[i] for p in out.pareto_front]
        println("  ", task, ": front range [", round(minimum(vals); digits=3), ", ", round(maximum(vals); digits=3), "]")
    end
    println("best_mean_objectives=", round.(out.best_mean_objectives; digits=3))

    genome = out.best_mean_genome
    tag = Benchmark.Store.genome_tag(genome)
    git = Benchmark.Store.git_sha(Benchmark.Store.repo_root())
    manifest = Dict{String,Any}(
        "git_sha" => git,
        "neuron" => "compartmental_structured_nsga",
        "method" => "nsga2",
        "train_tasks" => String.(collect(TASKS)),
        "popsize" => out.config.popsize,
        "generations" => out.config.generations,
        "k_trials" => out.config.k_trials,
        "N" => out.config.N,
        "ticks" => out.config.ticks,
        "seed" => out.config.seed,
        "n_evaluated" => out.n_evaluated,
        "pareto_front_size" => length(out.pareto_front),
        "best_mean_objectives" => out.best_mean_objectives,
        "timestamp_utc" => Benchmark.Store.timestamp_utc(),
        "tag" => tag,
        "note" => "single generalist genome (highest mean objective on the final Pareto-eligible population), saved identically under every task cell",
    )

    for task in TASKS
        entry = Benchmark.Store.save_genome_entry(Benchmark.Store.bench_dir(), :compartmental_structured_nsga, task, genome, manifest)
        println("saved -> ", entry.dir)
    end
end

main()
