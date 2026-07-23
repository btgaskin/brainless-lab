using BrainlessLab
using Test

include("testutils.jl")
include("suites.jl")

validate_test_suites()

suite = parse_test_suite(get(ENV, "BRAINLESSLAB_TEST_SUITE", "core"))
files = test_files_for(suite)
@info "Running BrainlessLab test suite" suite files=length(files)

for file in files
    include(file)
end
