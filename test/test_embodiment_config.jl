@testset "embodiment TOML configuration" begin
    root = pkgdir(BrainlessLab)
    examples = (
        joinpath(root, "examples", "embodiments", "differential_robot.toml"),
        joinpath(root, "examples", "embodiments", "planar_uav.toml"),
        joinpath(root, "examples", "embodiments", "bilateral_insect.toml"),
    )

    configs = read_embodiment_config.(examples)
    @test getfield.(configs, :name) == (:differential_robot, :planar_uav, :bilateral_insect)
    @test all(config -> config.schema_version == EMBODIMENT_SCHEMA_VERSION, configs)
    @test all(config -> isabspath(config.source), configs)
    @test [component.id for component in configs[1].components] ==
          [:chassis, :camera, :wheels, :motion]
    @test configs[1].components[2].parameters.channels == ("red", "green", "blue")
    @test configs[2].components[3].parameters.mount == (0.12, 0.18)
    @test configs[3].components[4].family === :encoder

    canonical = embodiment_config_namedtuple(configs[1])
    @test propertynames(canonical) == (:schema_version, :name, :components)
    @test canonical.name == "differential_robot"
    @test canonical.components[1].parameters == (radius=0.35,)
    @test !occursin(configs[1].source, canonical_embodiment_toml(configs[1]))

    mktempdir() do temp
        canonical_path = joinpath(temp, "canonical.toml")
        @test write_embodiment_config(canonical_path, configs[1]) == canonical_path
        roundtrip = read_embodiment_config(canonical_path)
        @test embodiment_config_namedtuple(roundtrip) == canonical

        base_path = joinpath(temp, "base.toml")
        cp(examples[1], base_path)
        derived_path = joinpath(temp, "derived.toml")
        write(derived_path, """
            schema_version = 1
            name = "fast_robot"
            extends = "base.toml"

            [overrides]
            "camera.range" = 14.0
            "wheels.max_speed" = 1.8
            """)
        derived = read_embodiment_config(derived_path)
        @test derived.name === :fast_robot
        @test derived.components[2].parameters.range == 14.0
        @test derived.components[3].parameters.max_speed == 1.8
        @test configs[1].components[2].parameters.range == 8.0

        bad_override = joinpath(temp, "bad_override.toml")
        write(bad_override, """
            schema_version = 1
            name = "bad_override"
            extends = "base.toml"
            [overrides]
            "missing.range" = 2.0
            """)
        @test_throws ArgumentError read_embodiment_config(bad_override)

        append_parameter = joinpath(temp, "append_parameter.toml")
        write(append_parameter, """
            schema_version = 1
            name = "append_parameter"
            extends = "base.toml"
            [overrides]
            "camera.new_parameter" = 2.0
            """)
        @test_throws ArgumentError read_embodiment_config(append_parameter)

        structural_override = joinpath(temp, "structural_override.toml")
        write(structural_override, """
            schema_version = 1
            name = "structural_override"
            extends = "base.toml"
            [overrides]
            "camera.kind" = "other_camera"
            """)
        @test_throws ArgumentError read_embodiment_config(structural_override)

        unquoted_override = joinpath(temp, "unquoted_override.toml")
        write(unquoted_override, """
            schema_version = 1
            name = "unquoted_override"
            extends = "base.toml"
            [overrides.camera]
            range = 4.0
            """)
        @test_throws ArgumentError read_embodiment_config(unquoted_override)

        extends_with_components = joinpath(temp, "extends_with_components.toml")
        write(extends_with_components, """
            schema_version = 1
            name = "extends_with_components"
            extends = "base.toml"
            [[components]]
            id = "extra"
            family = "sensor"
            kind = "field_probe"
            """)
        @test_throws ArgumentError read_embodiment_config(extends_with_components)

        self_path = joinpath(temp, "self.toml")
        write(self_path, """
            schema_version = 1
            name = "self"
            extends = "self.toml"
            """)
        @test_throws ArgumentError read_embodiment_config(self_path)

        absolute_base = joinpath(temp, "absolute_base.toml")
        write(absolute_base, """
            schema_version = 1
            name = "absolute_base"
            extends = "$(base_path)"
            """)
        @test_throws ArgumentError read_embodiment_config(absolute_base)

        nested_base = joinpath(temp, "nested_base.toml")
        write(nested_base, """
            schema_version = 1
            name = "nested_base"
            extends = "base.toml"
            """)
        nested_child = joinpath(temp, "nested_child.toml")
        write(nested_child, """
            schema_version = 1
            name = "nested_child"
            extends = "nested_base.toml"
            """)
        @test_throws ArgumentError read_embodiment_config(nested_child)

        unknown_key = joinpath(temp, "unknown.toml")
        write(unknown_key, """
            schema_version = 1
            name = "unknown"
            surprise = true
            [[components]]
            id = "shape"
            family = "geometry"
            kind = "disc"
            """)
        @test_throws ArgumentError read_embodiment_config(unknown_key)

        unknown_component_key = joinpath(temp, "unknown_component.toml")
        write(unknown_component_key, """
            schema_version = 1
            name = "unknown_component"
            [[components]]
            id = "shape"
            family = "geometry"
            kind = "disc"
            radius = 0.5
            """)
        @test_throws ArgumentError read_embodiment_config(unknown_component_key)

        duplicate = joinpath(temp, "duplicate.toml")
        write(duplicate, """
            schema_version = 1
            name = "duplicate"
            [[components]]
            id = "shape"
            family = "geometry"
            kind = "disc"
            [[components]]
            id = "shape"
            family = "sensor"
            kind = "field_probe"
            """)
        @test_throws ArgumentError read_embodiment_config(duplicate)

        dotted_id = joinpath(temp, "dotted_id.toml")
        write(dotted_id, """
            schema_version = 1
            name = "dotted_id"
            [[components]]
            id = "left.sensor"
            family = "sensor"
            kind = "field_probe"
            """)
        @test_throws ArgumentError read_embodiment_config(dotted_id)

        legacy_key = joinpath(temp, "legacy_key.toml")
        write(legacy_key, """
            schema_version = 1
            name = "legacy_key"
            [ven]
            sensor_count = 62
            """)
        legacy_error = try
            read_embodiment_config(legacy_key)
            nothing
        catch err
            err
        end
        @test legacy_error isa ArgumentError
        @test occursin("legacy embodiment key `ven`", sprint(showerror, legacy_error))

        legacy_family = joinpath(temp, "legacy_family.toml")
        write(legacy_family, """
            schema_version = 1
            name = "legacy_family"
            [[components]]
            id = "drive"
            family = "motor"
            kind = "kinematic"
            """)
        family_error = try
            read_embodiment_config(legacy_family)
            nothing
        catch err
            err
        end
        @test family_error isa ArgumentError
        @test occursin("legacy component family :motor", sprint(showerror, family_error))

        bad_schema = joinpath(temp, "bad_schema.toml")
        write(bad_schema, """
            schema_version = 2
            name = "future"
            [[components]]
            id = "shape"
            family = "geometry"
            kind = "disc"
            """)
        @test_throws ArgumentError read_embodiment_config(bad_schema)
    end

    registered = Tuple{Symbol,Symbol}[]
    previous_descriptors = Dict{Tuple{Symbol,Symbol},Any}()
    calls = Ref(0)
    kinds = unique((component.family, component.kind) for config in configs for component in config.components)
    try
        for (family, kind) in kinds
            key = (family, kind)
            previous_descriptors[key] = get(BrainlessLab.COMPONENTS, key, nothing)
            example = family === :encoder ? examples[3] : family === :dynamics && kind === :planar_rigid_body ? examples[2] : examples[1]
            resolver = component -> begin
                calls[] += 1
                return (id=component.id, state=Float64[], parameters=component.parameters)
            end
            descriptor = ComponentDescriptor(
                family,
                kind,
                resolver;
                readiness=:available,
                capabilities=(:config_materialization,),
                conformance=:embodiment_config_contract,
                conformance_path="test/test_embodiment_config.jl",
                docs_path="site/src/content/docs/contracts.mdx",
                example_path=relpath(example, root),
                root=root,
            )
            register_component!(descriptor; replace=true)
            push!(registered, (family, kind))
        end

        first_blueprints = materialize_blueprint.(configs)
        second_blueprints = materialize_blueprint.(configs)
        expected_calls = 2 * sum(length(config.components) for config in configs)
        @test calls[] == expected_calls
        @test all(blueprint -> blueprint isa EmbodimentBlueprint, first_blueprints)
        @test first_blueprints[1].components isa Tuple
        @test first_blueprints[1].components[1].id === :chassis
        @test first_blueprints[1].components[1].value.state !==
              second_blueprints[1].components[1].value.state
        @test isempty(first_blueprints[1].components[1].value.state)
        push!(first_blueprints[1].components[1].value.state, 1.0)
        @test isempty(second_blueprints[1].components[1].value.state)
    finally
        for key in registered
            previous = previous_descriptors[key]
            previous === nothing ?
                delete!(BrainlessLab.COMPONENTS, key) :
                (BrainlessLab.COMPONENTS[key] = previous)
        end
    end
end

@testset "unsupported component families are retained then rejected explicitly" begin
    root = pkgdir(BrainlessLab)
    key = (:accessory, :test_tag)
    previous = get(BrainlessLab.COMPONENTS, key, nothing)
    descriptor = ComponentDescriptor(
        key...,
        component -> (tag=component.id,);
        readiness=:available,
        capabilities=(:config_materialization,),
        conformance=:embodiment_config_contract,
        conformance_path="test/test_embodiment_config.jl",
        docs_path="site/src/content/docs/contracts.mdx",
        example_path="examples/embodiments/differential_robot.toml",
        root=root,
    )
    try
        register_component!(descriptor; replace=true)
        component = ComponentConfig(:status_light, key..., NamedTuple())
        config = EmbodimentConfig(1, :tagged_robot, (component,))
        blueprint = materialize_blueprint(config)
        @test only(blueprint.components).family === :accessory

        err = try
            materialize_embodiment(config)
            nothing
        catch caught
            caught
        end
        @test err isa ArgumentError
        message = sprint(showerror, err)
        @test occursin(":status_light", message)
        @test occursin(":accessory", message)
    finally
        previous === nothing ?
            delete!(BrainlessLab.COMPONENTS, key) :
            (BrainlessLab.COMPONENTS[key] = previous)
    end
end
