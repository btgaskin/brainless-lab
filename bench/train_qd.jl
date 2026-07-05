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

# CMA-ME training driver: illuminates a MAP-Elites archive over discretized
# per-task-score descriptors for compartmental_structured, using sep-CMA-ES
# improvement emitters (see src/drivers/QualityDiversity.jl). Saves the
# highest-quality archive elite as the genome for the
# :compartmental_structured_cmame bench roster alias.

include("Benchmark.jl")
using .Benchmark
using BrainlessLab

const TASKS = (:wall, :tracking, :pong, :cartpole, :cartpole_swingup)

function main()
    t0 = time()
    out = BrainlessLab.cma_me(
        model_sym=:compartmental_structured,
        train_tasks=TASKS,
        bins=5,
        n_emitters=4,
        emitter_popsize=6,
        iterations=50,
        k_trials=4,
        N=200,
        ticks=300,
        seed=0,
    )
    elapsed = time() - t0

    println("n_evaluated=", out.n_evaluated, "  elapsed_s=", round(elapsed; digits=1))
    println("archive coverage=", round(out.coverage; digits=4), "  filled=", out.n_cells_filled, "/", out.n_cells_total)
    println("pareto cells=", length(out.pareto_front))
    println("best_quality=", round(out.best_quality; digits=3), "  best_descriptor=", round.(out.best_descriptor; digits=3))
    for (i, task) in enumerate(TASKS)
        vals = [p.descriptor[i] for p in out.pareto_front]
        println("  ", task, ": pareto range [", round(minimum(vals); digits=3), ", ", round(maximum(vals); digits=3), "]")
    end

    genome = out.best_genome
    tag = Benchmark.Store.genome_tag(genome)
    git = Benchmark.Store.git_sha(Benchmark.Store.repo_root())
    manifest = Dict{String,Any}(
        "git_sha" => git,
        "neuron" => "compartmental_structured_cmame",
        "method" => "cma_me",
        "train_tasks" => String.(collect(TASKS)),
        "bins" => out.config.bins,
        "n_emitters" => out.config.n_emitters,
        "emitter_popsize" => out.config.emitter_popsize,
        "iterations" => out.config.iterations,
        "k_trials" => out.config.k_trials,
        "N" => out.config.N,
        "ticks" => out.config.ticks,
        "seed" => out.config.seed,
        "n_evaluated" => out.n_evaluated,
        "coverage" => out.coverage,
        "n_cells_filled" => out.n_cells_filled,
        "best_quality" => out.best_quality,
        "best_descriptor" => out.best_descriptor,
        "timestamp_utc" => Benchmark.Store.timestamp_utc(),
        "tag" => tag,
        "note" => "single highest-quality archive elite, saved identically under every task cell",
    )

    for task in TASKS
        entry = Benchmark.Store.save_genome_entry(Benchmark.Store.bench_dir(), :compartmental_structured_cmame, task, genome, manifest)
        println("saved -> ", entry.dir)
    end
end

main()
