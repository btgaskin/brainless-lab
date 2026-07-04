#!/usr/bin/env julia

# Re-exec with `-t auto` so independent rollouts can use all performance cores
# when Julia was launched single-threaded and the user did not pin a count.
if Threads.nthreads() == 1 &&
   !haskey(ENV, "JULIA_NUM_THREADS") &&
   get(ENV, "BRAINLESSLAB_AUTOTHREADS", "1") != "0"
    _cmd = addenv(
        `$(Base.julia_cmd()) --threads=auto --project=$(Base.active_project()) $(abspath(PROGRAM_FILE)) $(ARGS)`,
        "BRAINLESSLAB_AUTOTHREADS" => "0",
    )
    _proc = run(ignorestatus(_cmd))
    exit(_proc.exitcode)
end

using BrainlessLab

const _DEBUG_FLAGS = ("--debug", "--verbose")

if !("--help" in ARGS || "-h" in ARGS || "--list-axes" in ARGS)
    try
        @eval using CairoMakie
    catch err
        @warn "CairoMakie could not be loaded; sweep figures/GIFs may fall back to placeholders" error=sprint(showerror, err)
    end
end

function _usage(io=stdout)
    println(io, """
    Usage:
      julia --project=. sweep/run.jl CONFIG.toml [--force] [--debug]
      julia --project=. sweep/run.jl --list-axes --node falandays_base --task wall
      julia --project=. sweep/run.jl ablate NODE TASK [--force] [--debug]

    Rollouts run in parallel across Julia threads; the script re-launches
    itself with `-t auto` when started single-threaded. Opt out with
    BRAINLESSLAB_AUTOTHREADS=0 or JULIA_NUM_THREADS=1, or set
    `sweep.threaded = false` in the TOML.
    """)
end

function _arg_value(args, name, default)
    idx = findfirst(==(name), args)
    idx === nothing && return default
    idx == length(args) && error("missing value after $(name)")
    return args[idx + 1]
end

function _print_axes(node, task)
    axes = sweepable_axes(Symbol(node), Symbol(task))
    println("Sweepable axes for node=:$(Symbol(node)), task=:$(Symbol(task))")
    for axis in axes
        default = axis.default === nothing ? "nothing" : string(axis.default)
        range = isempty(axis.range) ? "" : " range=$(axis.range)"
        println(rpad(axis.path, 28), " default=", default, range, "  ", axis.description)
    end
end

function main(args=ARGS)
    args = [arg for arg in args if !(arg in _DEBUG_FLAGS)]
    if "--help" in args || "-h" in args
        _usage()
        return 0
    end
    isempty(args) && (_usage(stderr); return 1)

    if "--list-axes" in args
        node = _arg_value(args, "--node", "falandays_base")
        task = _arg_value(args, "--task", "wall")
        _print_axes(node, task)
        return 0
    end

    init_parallelism!(verbose=true)

    force = "--force" in args
    if first(args) == "ablate"
        length(args) >= 3 || error("ablate requires NODE TASK")
        out = ablate(Symbol(args[2]), Symbol(args[3]); force=force)
        println("Wrote ablation sweep: ", out.dir)
        return 0
    end

    config = first(args)
    out = run_sweep(config; force=force)
    println("Wrote sweep: ", out.dir)
    return 0
end

function _entrypoint(args=ARGS)
    debug = any(flag -> flag in args, _DEBUG_FLAGS)
    try
        return main(args)
    catch err
        debug && rethrow()
        println(stderr, "error: ", sprint(showerror, err))
        _usage(stderr)
        return 1
    end
end

exit(_entrypoint())
