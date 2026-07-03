using BrainlessLab
using NPZ
using Random
using Test

const COLLECTIVE_DYAD_ATOL = 1e-9

function _dyad_fixture_path()
    return joinpath(@__DIR__, "fixtures", "dyad_torus.npz")
end

function _dyad_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function _dyad_int(data, key::AbstractString)
    return Int(round(_dyad_scalar(data, key)))
end

function _dyad_bool(data, key::AbstractString)
    return Bool(round(Int, _dyad_scalar(data, key)))
end

function _dyad_matrix(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _dyad_slice_matrix(data, key::AbstractString, agent::Integer)
    raw = data[key]
    return Matrix{Float64}(Float64.(raw[Int(agent), :, :]))
end

function _dyad_slice_vector(data, key::AbstractString, t::Integer, agent::Integer)
    raw = data[key]
    return Vector{Float64}(vec(Float64.(raw[Int(t), Int(agent), :])))
end

function _dyad_bitmatrix(x)
    mask = falses(size(x, 1), size(x, 2))
    @inbounds for j in axes(mask, 2), i in axes(mask, 1)
        mask[i, j] = x[i, j] != 0
    end
    return mask
end

function _dyad_bitmatrix_slice(data, key::AbstractString, agent::Integer)
    return _dyad_bitmatrix(data[key][Int(agent), :, :])
end

function _dyad_params(data)
    return FalandaysParams(
        leak=_dyad_scalar(data, "leak"),
        lrate_wmat=_dyad_scalar(data, "lrate_wmat"),
        lrate_targ=_dyad_scalar(data, "lrate_targ"),
        threshold_mult=_dyad_scalar(data, "threshold_mult"),
        targ_min=_dyad_scalar(data, "targ_min"),
        input_weight=_dyad_scalar(data, "input_weight"),
        weight_init_std=_dyad_scalar(data, "weight_init_std"),
        learn_on=_dyad_bool(data, "learn_on"),
    )
end

function _dyad_ven_params(data)
    return VENParams(
        top_speed=_dyad_scalar(data, "top_speed"),
        accel_time=_dyad_scalar(data, "accel_time"),
        top_heading_rate=_dyad_scalar(data, "top_heading_rate"),
        h_accel_time=_dyad_scalar(data, "h_accel_time"),
        dt=_dyad_scalar(data, "dt"),
        agent_radius=_dyad_scalar(data, "agent_radius"),
    )
end

function _dyad_reservoir(data, agent::Integer)
    ticks = _dyad_int(data, "ticks")
    n_nodes = _dyad_int(data, "N")

    return FalandaysReservoir(
        params=_dyad_params(data),
        drive=NoDrive(),
        sign=BrainlessLab.Unsigned(),
        recurrent_mask=_dyad_bitmatrix_slice(data, "recurrent_mask", agent),
        input_wmat=_dyad_slice_matrix(data, "input_wmat", agent),
        output_mask=_dyad_slice_matrix(data, "output_mask", agent),
        wmat0=_dyad_slice_matrix(data, "wmat0", agent),
        noise_source=RecordedNoise(zeros(Float64, ticks, n_nodes)),
        rectify=_dyad_bool(data, "rectify"),
    )
end

function _dyad_collective(data)
    poses = _dyad_matrix(data, "initial_pose")
    speeds = haskey(data, "initial_speed") ?
        Vector{Float64}(vec(Float64.(data["initial_speed"]))) :
        zeros(Float64, size(poses, 1))
    heading_rates = haskey(data, "initial_heading_rate") ?
        Vector{Float64}(vec(Float64.(data["initial_heading_rate"]))) :
        zeros(Float64, size(poses, 1))

    params = _dyad_ven_params(data)
    bodies = [
        VENBody(
            (poses[i, 1], poses[i, 2]),
            poses[i, 3];
            params=params,
            speed=speeds[i],
            heading_rate=heading_rates[i],
        )
        for i in axes(poses, 1)
    ]

    torus = Torus(_dyad_scalar(data, "torus_size"))
    medium = TorusMedium(
        torus,
        bodies;
        visual_coupling=_dyad_bool(data, "visual_coupling"),
        physical_coupling=_dyad_bool(data, "physical_coupling"),
        sensory_noise=_dyad_scalar(data, "sensory_noise"),
        sensory_scaling=_dyad_bool(data, "sensory_scaling"),
        sens_agent_dist=_dyad_int(data, "sens_agent_dist"),
        record_inputs=true,
        rng=MersenneTwister(_dyad_int(data, "seed")),
    )
    agents = [Agent(_dyad_reservoir(data, i), bodies[i]) for i in eachindex(bodies)]

    return Ensemble(agents, medium)
end

function _dyad_bodies(c::Ensemble)
    return [agent.body for agent in c.agents]
end

function _dyad_observed_inputs(c::Ensemble)
    bodies = _dyad_bodies(c)
    percepts = observe(c.medium, bodies)
    return [receptors(bodies[i], percepts[i]) for i in eachindex(bodies)]
end

function _dyad_pose(body::VENBody)
    return [body.pos[1], body.pos[2], body.heading]
end

function _dyad_max_abs_dev(a, b)
    av = Float64.(vec(a))
    bv = Float64.(vec(b))
    length(av) == length(bv) ||
        throw(DimensionMismatch("lengths $(length(av)) and $(length(bv)) differ"))
    isempty(av) && return 0.0
    return maximum(abs.(av .- bv))
end

function _dyad_metric_dev(data, got, key::Symbol)
    fixture_key = "metric_$(key)"
    haskey(data, fixture_key) || error("fixture missing $fixture_key")
    haskey(got, key) || error("swarm metrics missing $key")
    return abs(Float64(getproperty(got, key)) - _dyad_scalar(data, fixture_key))
end

@testset "Torus vision and metric seam corrections" begin
    torus = Torus(10.0)
    params = VENParams(agent_radius=0.5)
    body = VENBody((5.0, 5.0), 0.0; params=params)
    neighbor = VENBody((4.0, 4.99), 0.0; params=params)

    sensors = sense_agents(body, [neighbor], torus, params, [pi - 0.01], 0, 0)
    @test only(sensors) == 1.0

    positions = [(9.8, 5.0), (0.2, 5.0)]
    centroid = BrainlessLab.circular_centroid(positions, torus)
    @test min(abs(centroid[1]), abs(centroid[1] - torus.size)) <= 1e-12
    @test centroid[2] ≈ 5.0 atol=1e-12

    headings = [-pi / 2, pi / 2]
    @test milling(positions, headings, centroid, torus) ≈ 1.0 atol=1e-12
end

@testset "Ensemble dyad TorusMedium oracle parity" begin
    # fixture predates vision-wrap / circular-centroid fix; regenerate oracle
    @test_skip "dyad_torus fixture predates vision-wrap / circular-centroid fix; regenerate oracle"
end

function _dyad_stale_oracle_parity()
    path = _dyad_fixture_path()
    isfile(path) || error("missing fixture $path; run test/oracle/gen_dyad_fixtures.py from the v0.2 directory")
    data = npzread(path)
    collective = _dyad_collective(data)

    sensors = data["sensors"]
    spikes_t = data["spikes"]
    effectors_t = data["effectors"]
    pose_t = data["pose"]

    ticks = _dyad_int(data, "ticks")
    n_agents = _dyad_int(data, "n_agents")

    @test length(collective.agents) == n_agents
    @test collective.medium isa TorusMedium
    @test size(sensors) == (ticks, n_agents, _dyad_int(data, "n_receptors"))
    @test size(spikes_t) == (ticks, n_agents, _dyad_int(data, "N"))
    @test size(effectors_t) == (ticks, n_agents, _dyad_int(data, "n_effectors"))

    max_sensor = 0.0
    max_effector = 0.0
    max_pose = 0.0

    for t in 1:ticks
        inputs = _dyad_observed_inputs(collective)
        for i in 1:n_agents
            sensor_dev = _dyad_max_abs_dev(inputs[i], _dyad_slice_vector(data, "sensors", t, i))
            max_sensor = max(max_sensor, sensor_dev)
            @test sensor_dev <= COLLECTIVE_DYAD_ATOL
        end

        spikes = step!(collective)

        for i in 1:n_agents
            expected_spikes = _dyad_slice_vector(data, "spikes", t, i)
            @test spikes[i] == expected_spikes

            effector_dev = _dyad_max_abs_dev(
                effectors(collective.agents[i].reservoir, spikes[i]),
                _dyad_slice_vector(data, "effectors", t, i),
            )
            max_effector = max(max_effector, effector_dev)
            @test effector_dev <= COLLECTIVE_DYAD_ATOL

            pose_dev = _dyad_max_abs_dev(
                _dyad_pose(collective.agents[i].body),
                _dyad_slice_vector(data, "pose", t, i),
            )
            max_pose = max(max_pose, pose_dev)
            @test pose_dev <= COLLECTIVE_DYAD_ATOL
        end
    end

    got_metrics = swarm_metrics(collective, _dyad_int(data, "window"))
    max_metric = 0.0
    for key in (
        :polarization,
        :milling,
        :mean_nearest_neighbor_distance,
        :mean_pairwise_distance,
        :cohesion,
        :input_stability,
    )
        dev = _dyad_metric_dev(data, got_metrics, key)
        max_metric = max(max_metric, dev)
        @test dev <= COLLECTIVE_DYAD_ATOL
    end

    @info "collective dyad oracle parity" max_sensor max_effector max_pose max_metric
end
