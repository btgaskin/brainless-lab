#!/usr/bin/env julia

using BrainlessLab

include("my_node.jl")
include("my_task.jl")
include("my_metric.jl")

plan_path = isempty(ARGS) ? joinpath(@__DIR__, "config.toml") : ARGS[1]
root = length(ARGS) >= 2 ? ARGS[2] : joinpath(@__DIR__, "records")
plan = read_plan(plan_path)
run = run_operation(plan; root=root)
println("record: ", run.directory)
println("summary: ", summary(run.result))
