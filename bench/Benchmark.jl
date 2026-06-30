module Benchmark

include("src/Stats.jl")
include("src/Store.jl")
include("src/Pipeline.jl")

using .Pipeline: BenchConfig, parse_symbol_list, print_short_summary, read_bench_config, run_benchmark

export BenchConfig,
    parse_symbol_list,
    print_short_summary,
    read_bench_config,
    run_benchmark

end
