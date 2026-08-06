@testset "component readiness catalog" begin
    mktempdir() do root
        mkpath(joinpath(root, "docs"))
        mkpath(joinpath(root, "examples"))
        mkpath(joinpath(root, "test"))
        write(joinpath(root, "docs", "components.md"), "# Components\n")
        write(joinpath(root, "examples", "component.jl"), "nothing\n")
        write(joinpath(root, "test", "conformance.jl"), "nothing\n")

        common = (
            conformance=:catalog_contract,
            conformance_path="test/conformance.jl",
            docs_path="docs/components.md",
            example_path="examples/component.jl",
            root=root,
        )
        registered_keys = Tuple{Symbol,Symbol}[]

        try
            available = BrainlessLab.ComponentDescriptor(
                :sensor,
                :catalog_available,
                identity;
                readiness=:available,
                capabilities=(:sampling,),
                parameters=(required=(:channel,), optional=(:gain,)),
                common...,
            )
            integrated = BrainlessLab.ComponentDescriptor(
                :sensor,
                :catalog_integrated,
                identity;
                readiness=:integrated,
                capabilities=(:sampling, :recording),
                common...,
            )
            core = BrainlessLab.ComponentDescriptor(
                :actuator,
                :catalog_core,
                identity;
                readiness=:core,
                capabilities=(:decoding, :recording),
                core_tests=(:actuator_contract, :mixed_composition),
                common...,
            )

            for descriptor in (available, integrated, core)
                push!(registered_keys, (descriptor.family, descriptor.kind))
                @test BrainlessLab.register_component!(descriptor) === descriptor
                @test BrainlessLab.validate_component_descriptor(descriptor) === descriptor
            @test descriptor.status === :experimental
            end

            @test BrainlessLab.resolve_component(:sensor, :catalog_available) === available
            @test BrainlessLab.component_info("sensor", "catalog_integrated") === integrated
            @test BrainlessLab.readiness(:actuator, :catalog_core) === :core
            @test_throws KeyError BrainlessLab.component_info(:sensor, :catalog_missing)

            catalog_only = descriptor -> startswith(String(descriptor.kind), "catalog_")
            sensor_components = filter(catalog_only, BrainlessLab.components(family=:sensor))
            @test [descriptor.kind for descriptor in sensor_components] ==
                  [:catalog_available, :catalog_integrated]
            @test [descriptor.kind for descriptor in filter(catalog_only, BrainlessLab.components(readiness=:integrated))] ==
                  [:catalog_core, :catalog_integrated]
            @test [descriptor.kind for descriptor in filter(catalog_only, BrainlessLab.components(readiness=:core))] ==
                  [:catalog_core]
            @test_throws ArgumentError BrainlessLab.components(readiness=:unknown)

            rows = BrainlessLab.readiness()
            integrated_row = only(row for row in rows if row.kind === :catalog_integrated)
            @test integrated_row.status === :experimental
            @test integrated_row.capabilities == (:sampling, :recording)
            @test available.parameters == (required=(:channel,), optional=(:gain,))
            @test integrated_row.parameters == (required=(), optional=())
            @test integrated_row.conformance === :catalog_contract

            markdown = BrainlessLab.readiness_markdown()
            @test startswith(markdown, "| Family | Component | Status | Readiness |")
            @test occursin(":catalog_available", markdown)
            @test occursin(":actuator_contract, :mixed_composition", markdown)

            replacement = BrainlessLab.ComponentDescriptor(
                :sensor,
                :catalog_available,
                identity;
                readiness=:integrated,
                capabilities=(:sampling,),
                common...,
            )
            @test_throws ArgumentError BrainlessLab.register_component!(replacement)
            @test BrainlessLab.register_component!(replacement; replace=true) === replacement
            @test BrainlessLab.component_info(:sensor, :catalog_available) === replacement

            bad_status = BrainlessLab.ComponentDescriptor(
                :invalid,
                :status,
                identity;
                status=:stable,
                common...,
            )
            @test_throws ArgumentError BrainlessLab.register_component!(bad_status)

            bad_readiness = BrainlessLab.ComponentDescriptor(
                :invalid,
                :readiness,
                identity;
                readiness=:reference,
                common...,
            )
            @test_throws ArgumentError BrainlessLab.register_component!(bad_readiness)

            @test_throws ArgumentError BrainlessLab.ComponentDescriptor(
                :invalid,
                :parameters,
                identity;
                parameters=(required=(:gain,), optional=(:gain,)),
                common...,
            )

            noncallable = BrainlessLab.ComponentDescriptor(
                :invalid,
                :resolver,
                1;
                common...,
            )
            @test_throws ArgumentError BrainlessLab.register_component!(noncallable)

            missing_evidence = BrainlessLab.ComponentDescriptor(
                :invalid,
                :evidence,
                identity;
                conformance=:catalog_contract,
                conformance_path="test/missing.jl",
                docs_path="docs/components.md",
                example_path="examples/component.jl",
                root=root,
            )
            @test_throws ArgumentError BrainlessLab.register_component!(missing_evidence)

            uncovered_core = BrainlessLab.ComponentDescriptor(
                :invalid,
                :uncovered_core,
                identity;
                readiness=:core,
                common...,
            )
            @test_throws ArgumentError BrainlessLab.register_component!(uncovered_core)
        finally
            for key in registered_keys
                delete!(BrainlessLab.COMPONENTS, key)
            end
        end
    end
end
