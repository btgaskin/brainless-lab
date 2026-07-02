using BrainlessLab
using Random
using StaticArrays
using Test

function _delay_embedding(N::Integer)
    positions = [SVector{2,Float64}(Float64(i), 0.0) for i in 1:Int(N)]
    return Embedding(positions, SVector{2,Float64}[], SVector{2,Float64}[])
end

function _delayed_clone_from_dense(dense, embedding, delays, maxdelay, all_unit, noise_draws)
    n_nodes = size(dense.wmat0, 1)
    connectome = DelayedConnectome{2}(
        copy(dense.recurrent_mask),
        copy(dense.input_wmat),
        copy(dense.output_mask),
        copy(dense.wmat0),
        embedding,
        ones(Int, n_nodes),
        delays,
        maxdelay,
        all_unit,
    )
    conn = all_unit ?
        FalandaysConnState(copy(dense.wmat0)) :
        FalandaysConnState(copy(dense.wmat0), SpikeHistory(n_nodes, maxdelay))

    return ReservoirInstance(
        FalandaysModel(dense.params, dense.drive, dense.sign, dense.rectify),
        connectome,
        conn,
        FalandaysNodeState(
            zeros(Float64, n_nodes),
            ones(Float64, n_nodes),
            zeros(Float64, n_nodes),
            zeros(Float64, n_nodes),
            zeros(Float64, n_nodes),
            RecordedNoise(copy(noise_draws)),
        ),
        PortSpec(size(dense.input_wmat, 1), size(dense.output_mask, 2)),
    )
end

@testset "Delayed Falandays unit-delay byte parity" begin
    ticks = 100
    n_nodes = 18
    n_receptors_ = 4
    n_effectors_ = 2
    params = FalandaysParams()
    rng = MersenneTwister(41)
    noise_draws = randn(rng, ticks, n_nodes)
    receptor_stream = rand(rng, ticks, n_receptors_)

    dense = FalandaysReservoir(
        n_nodes,
        n_receptors_,
        n_effectors_;
        seed=7,
        params=params,
        noise_source=RecordedNoise(copy(noise_draws)),
    )
    embedding = _delay_embedding(n_nodes)
    delays, maxdelay, all_unit =
        delays_from_embedding(embedding, dense.recurrent_mask, Inf, 1.0)
    delayed = _delayed_clone_from_dense(dense, embedding, delays, maxdelay, all_unit, noise_draws)

    @test all_unit
    @test delayed.conn.history === nothing

    for t in 1:ticks
        receptors = vec(receptor_stream[t, :])
        dense_spikes = step!(dense, receptors)
        delayed_spikes = step!(delayed, receptors)
        @test delayed_spikes == dense_spikes
        @test delayed.wmat == dense.wmat
    end
end

@testset "Delay mapping from conduction velocity" begin
    embedding = Embedding(
        SVector{2,Float64}[SVector(0.0, 0.0), SVector(2.0, 0.0), SVector(2.0, 1.0)],
        SVector{2,Float64}[],
        SVector{2,Float64}[],
    )
    mask = falses(3, 3)
    mask[1, 2] = true
    mask[2, 3] = true

    unit_delays, unit_maxdelay, unit_all =
        delays_from_embedding(embedding, mask, Inf, 1.0)
    @test all(unit_delays .== 1)
    @test unit_maxdelay == 1
    @test unit_all

    finite_delays, finite_maxdelay, finite_all =
        delays_from_embedding(embedding, mask, 0.5, 1.0)
    @test finite_delays[1, 2] == 4
    @test finite_delays[2, 3] == 2
    @test finite_maxdelay == 4
    @test any(finite_delays .> 1)
    @test !finite_all
end

function _tiny_delayed_reservoir(delay::Integer)
    n_nodes = 2
    recurrent_mask = falses(n_nodes, n_nodes)
    recurrent_mask[1, 2] = true
    input_wmat = [1.2 0.0]
    output_mask = reshape([0.0, 1.0], n_nodes, 1)
    wmat0 = zeros(Float64, n_nodes, n_nodes)
    wmat0[1, 2] = 1.2
    embedding = Embedding(
        SVector{2,Float64}[SVector(0.0, 0.0), SVector(2.0, 0.0)],
        SVector{2,Float64}[],
        SVector{2,Float64}[],
    )
    delays = ones(Int, n_nodes, n_nodes)
    delays[1, 2] = Int(delay)
    connectome = DelayedConnectome{2}(
        recurrent_mask,
        input_wmat,
        output_mask,
        wmat0,
        embedding,
        ones(Int, n_nodes),
        delays,
        Int(delay),
        false,
    )
    params = FalandaysParams(leak=1.0, threshold_mult=1.0, learn_on=false)

    return ReservoirInstance(
        FalandaysModel(params, NoDrive(), BrainlessLab.Unsigned(), true),
        connectome,
        FalandaysConnState(copy(wmat0), SpikeHistory(n_nodes, delay)),
        FalandaysNodeState(
            zeros(Float64, n_nodes),
            ones(Float64, n_nodes),
            zeros(Float64, n_nodes),
            zeros(Float64, n_nodes),
            zeros(Float64, n_nodes),
            RecordedNoise(zeros(Float64, Int(delay) + 2, n_nodes)),
        ),
        PortSpec(1, 1),
    )
end

@testset "Heterogeneous delay forward self-consistency" begin
    delay = 3
    reservoir = _tiny_delayed_reservoir(delay)
    spikes = Vector{Vector{Float64}}(undef, delay + 2)

    for t in 1:(delay + 2)
        receptors = t == 1 ? [1.2] : [0.0]
        spikes[t] = step!(reservoir, receptors)
    end

    @test spikes[1] == [1.0, 0.0]
    for t in 2:delay
        @test spikes[t] == [0.0, 0.0]
    end
    @test spikes[delay + 1] == [0.0, 1.0]
    @test spikes[delay + 2] == [0.0, 0.0]
end

@testset "Delayed Falandays builder and simulate smoke" begin
    c1 = build_delayed_connectome(
        24,
        3,
        2;
        rng=MersenneTwister(11),
        p0=1.0,
        lambda=10.0,
        conduction_velocity=0.05,
        weight_init_std=1.0,
        input_weight=1.875,
    )
    c2 = build_delayed_connectome(
        24,
        3,
        2;
        rng=MersenneTwister(11),
        p0=1.0,
        lambda=10.0,
        conduction_velocity=0.05,
        weight_init_std=1.0,
        input_weight=1.875,
    )
    @test c1.recurrent_mask == c2.recurrent_mask
    @test c1.input_wmat == c2.input_wmat
    @test c1.output_mask == c2.output_mask
    @test c1.wmat0 == c2.wmat0
    @test c1.embedding.node_pos == c2.embedding.node_pos
    @test c1.delays == c2.delays
    @test c1.maxdelay == c2.maxdelay
    @test c1.all_unit == c2.all_unit
    @test any(c1.delays .> 1)
    @test delaykind(c1) == HeteroDelay()

    r1 = resolve_node(:falandays_delayed)(
        24,
        3,
        2;
        seed=5,
        p0=1.0,
        lambda=10.0,
        conduction_velocity=0.05,
    )
    r2 = resolve_node(:falandays_delayed)(
        24,
        3,
        2;
        seed=5,
        p0=1.0,
        lambda=10.0,
        conduction_velocity=0.05,
    )
    @test r1.recurrent_mask == r2.recurrent_mask
    @test r1.input_wmat == r2.input_wmat
    @test r1.output_mask == r2.output_mask
    @test r1.wmat0 == r2.wmat0
    @test r1.connectome.delays == r2.connectome.delays
    @test r1.connectome.maxdelay == r2.connectome.maxdelay
    @test r1.connectome.all_unit == r2.connectome.all_unit

    sim_unit = simulate(:wall; node=:falandays_delayed, ticks=50, seed=1, conduction_velocity=Inf)
    sim_hetero = simulate(:wall; node=:falandays_delayed, ticks=50, seed=1, conduction_velocity=0.05)
    @test isfinite(Float64(sim_unit.metrics.score))
    @test isfinite(Float64(sim_hetero.metrics.score))
end
