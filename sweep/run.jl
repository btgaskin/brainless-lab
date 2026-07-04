#!/usr/bin/env julia

using BrainlessLab

function _usage()
    println("""
    Usage:
      julia --project=. sweep/run.jl CONFIG.toml [--force]
      julia --project=. sweep/run.jl --list-axes --node falandays_base --task wall
      julia --project=. sweep/run.jl ablate NODE TASK [--force]
    """)
end

function _arg_value(args, name, default)
    idx = findfirst(==(name), args)
    idx === nothing && return default
    idx == length(args) && error("missing value after $(name)")
    return args[idx + 1]
end

function _print_axes(node, task)
    println("Sweepable axes for node=:$(Symbol(node)), task=:$(Symbol(task))")
    for axis in sweepable_axes(Symbol(node), Symbol(task))
        default = axis.default === nothing ? "nothing" : string(axis.default)
        range = isempty(axis.range) ? "" : " range=$(axis.range)"
        println(rpad(axis.path, 28), " default=", default, range, "  ", axis.description)
    end
end

function main(args=ARGS)
    isempty(args) && (_usage(); return 1)

    if "--list-axes" in args
        node = _arg_value(args, "--node", "falandays_base")
        task = _arg_value(args, "--task", "wall")
        _print_axes(node, task)
        return 0
    end

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

exit(main())
