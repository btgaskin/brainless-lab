const TEST_SUITES = (
    core=(
        "test_package_quality.jl",
        "test_scaffold.jl",
        "test_components.jl",
        "test_public_vocabulary.jl",
        "test_documentation_contract.jl",
        "test_embodiment_config.jl",
        "test_component_catalog.jl",
        "test_contract_kernel.jl",
        "test_morphology.jl",
        "test_physical_components.jl",
        "test_situated.jl",
        "test_spectral_vision.jl",
        "test_bilateral_sensing.jl",
        "test_tracking_env_params.jl",
    ),
    runtime=(
        "test_composition_spec.jl",
        "test_core_platform.jl",
        "test_development.jl",
        "test_embodiment_runtime.jl",
        "test_object_world.jl",
        "test_object_world_arbitration.jl",
        "test_interaction_cycle.jl",
        "test_analysis.jl",
        "test_api.jl",
        "test_extension_points.jl",
        "test_colour.jl",
        "test_forage.jl",
        "test_homeostasis.jl",
        "test_homeostatic_flow_v2.jl",
        "test_interventions.jl",
        "test_mixed_ensemble.jl",
        "test_template_extension.jl",
        "test_motor.jl",
        "test_own_colour.jl",
        "test_plank_cartpole.jl",
        "test_delayed_cue.jl",
        "test_capacity_probes.jl",
        "test_ctrnn_runtime.jl",
        "test_sensor.jl",
        "test_shoal_forage.jl",
        "test_signalling.jl",
        "test_sorn.jl",
        "test_window.jl",
    ),
    operations=(
        "test_operation_plans.jl",
        "test_benchmark_plan.jl",
        "test_benchmark_specs.jl",
        "test_plan_io.jl",
        "test_profile_plan.jl",
        "test_probe_decodability.jl",
        "test_sweep_plan.jl",
        "test_ablation_plan.jl",
        "test_search_strategies.jl",
        "test_evolution_artifacts.jl",
        "test_evolution_plan.jl",
        "test_shared_evolution.jl",
        "test_records.jl",
        "test_plan_examples.jl",
        "test_experiment_io.jl",
        "test_research_contributions.jl",
    ),
    oracle=(
        "test_fixture_integrity.jl",
        "test_authors_parity.jl",
        "test_falandays.jl",
        "test_core_calibration.jl",
        "test_envs.jl",
        "test_ablation.jl",
        "test_compartmental.jl",
        "test_collective_single.jl",
        "test_paper_constants.jl",
        "test_core_task_controls.jl",
        "test_cartpole_variants.jl",
        "scoring_anchors.jl",
        "scoring_calibration.jl",
    ),
    legacy=(
        "test_collective_dyad.jl",
        "test_replay.jl",
    ),
)

# Visual tests require the optional plotting environment. They are intentionally
# outside every ordinary suite, including `all`.
const VISUAL_TEST_FILES = (
    "test_viz.jl",
    "test_examples.jl",
)

const TEST_INFRASTRUCTURE_FILES = Set((
    "runtests.jl",
    "suites.jl",
    "testutils.jl",
))

const TEST_SUITE_NAMES = (:core, :runtime, :operations, :oracle, :legacy, :all)

function parse_test_suite(value::AbstractString)
    suite = Symbol(lowercase(strip(value)))
    suite in TEST_SUITE_NAMES ||
        throw(ArgumentError(
            "unknown BRAINLESSLAB_TEST_SUITE=$(repr(value)); expected one of " *
            join(string.(TEST_SUITE_NAMES), ", "),
        ))
    return suite
end

function test_files_for(suite::Symbol)
    suite in TEST_SUITE_NAMES ||
        throw(ArgumentError("unknown test suite $(repr(suite))"))
    suite === :all && return collect(Iterators.flatten(values(TEST_SUITES)))
    return collect(getproperty(TEST_SUITES, suite))
end

function _duplicates(values)
    counts = Dict{String,Int}()
    for value in values
        counts[value] = get(counts, value, 0) + 1
    end
    return sort!([value for (value, count) in counts if count > 1])
end

function validate_test_suites(; root::AbstractString=@__DIR__)
    assigned = collect(Iterators.flatten(values(TEST_SUITES)))
    visual = collect(VISUAL_TEST_FILES)

    duplicates = _duplicates(assigned)
    isempty(duplicates) ||
        error("test files assigned to more than one suite: $(join(duplicates, ", "))")

    visual_duplicates = _duplicates(visual)
    isempty(visual_duplicates) ||
        error("visual test files declared more than once: $(join(visual_duplicates, ", "))")

    overlap = sort!(collect(intersect(Set(assigned), Set(visual))))
    isempty(overlap) ||
        error("visual test files must not belong to ordinary suites: $(join(overlap, ", "))")

    discovered = Set(
        file for file in readdir(root)
        if endswith(file, ".jl") && !(file in TEST_INFRASTRUCTURE_FILES)
    )
    declared = Set(vcat(assigned, visual))
    missing = sort!(collect(setdiff(discovered, declared)))
    extra = sort!(collect(setdiff(declared, discovered)))

    isempty(missing) ||
        error("top-level test files missing from suite declarations: $(join(missing, ", "))")
    isempty(extra) ||
        error("declared test files do not exist: $(join(extra, ", "))")

    return nothing
end
