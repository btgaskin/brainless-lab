using BrainlessLab
using CairoMakie
using Test

@testset "Runnable examples" begin
    examples_dir = normpath(joinpath(@__DIR__, "..", "examples"))
    scripts = sort(filter(path -> endswith(path, ".jl"), readdir(examples_dir; join=true)))
    @test !isempty(scripts)

    mktempdir() do output_dir
        key = "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR"
        old_value = get(ENV, key, nothing)
        ENV[key] = output_dir

        try
            for script in scripts
                before = count(endswith(".png"), readdir(output_dir))
                include(script)
                after = count(endswith(".png"), readdir(output_dir))
                @test after > before
            end
        finally
            if old_value === nothing
                delete!(ENV, key)
            else
                ENV[key] = old_value
            end
        end
    end
end
