using BrainlessLab
using Test

include("testutils.jl")
include("suites.jl")

validate_test_suites()

# Default to the whole suite. `Pkg.test()` is what a contributor, a reviewer, and
# anyone evaluating the package runs, so it must not report success after covering
# a fraction of the tests. The tiers exist to parallelise CI and to give a fast
# local loop; opt into one with BRAINLESSLAB_TEST_SUITE=core. Every CI job already
# sets the variable explicitly, so this changes nothing there.
suite = parse_test_suite(get(ENV, "BRAINLESSLAB_TEST_SUITE", "all"))
files = test_files_for(suite)
@info "Running BrainlessLab test suite" suite files=length(files)

@testset "BrainlessLab $(suite) suite" begin
    for file in files
        @testset "$file" begin
            include(file)
        end
    end
end
