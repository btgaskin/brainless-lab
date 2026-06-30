using BrainlessLab
using NPZ
using Test

const ABLATION_ATOL = 1e-9
const ABLATION_MARGIN_EPS = 1e-6

function _ablation_fixture_path(mode, ablation)
    return joinpath(@__DIR__, "fixtures", "ablation_$(mode)_$(ablation).npz")
end

function _ablation_int_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Int(value) : Int(only(value))
end

function _ablation_float_matrix(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _ablation_float_vector(data, key::AbstractString)
    return Vector{Float64}(vec(Float64.(data[key])))
end

function _ablation_flatten_c2(x::AbstractMatrix{<:Real})
    out = Vector{Float64}(undef, size(x, 1) * size(x, 2))
    idx = 1
    @inbounds for i in axes(x, 1), j in axes(x, 2)
        out[idx] = Float64(x[i, j])
        idx += 1
    end
    return out
end

function _ablation_flatten_c3(x::Array{<:Real,3})
    out = Vector{Float64}(undef, size(x, 1) * size(x, 2) * size(x, 3))
    idx = 1
    @inbounds for i in axes(x, 1), j in axes(x, 2), k in axes(x, 3)
        out[idx] = Float64(x[i, j, k])
        idx += 1
    end
    return out
end

function _ablation_max_abs_dev(a::AbstractVector{<:Real}, b::AbstractVector{<:Real})
    length(a) == length(b) || throw(DimensionMismatch("lengths $(length(a)) and $(length(b)) differ"))
    return isempty(a) ? 0.0 : maximum(abs.(Float64.(a) .- Float64.(b)))
end

function _ablation_intervention(mode::AbstractString)
    mode == "normal" && return nothing
    mode == "no_soma_back" && return NoSomaBack()
    mode == "no_hillock_back" && return NoHillockBack()
    mode == "reset_dendrites" && return ResetDendrites()
    throw(ArgumentError("unknown ablation mode $mode"))
end

function _build_ablation_reservoir(mode::AbstractString, ablation::AbstractString, data)
    raw = _ablation_float_vector(data, "raw")
    genome =
        mode == "dense" ?
        unpack_params(DenseCompartmental, raw) :
        unpack_params(StructuredCompartmental, raw)

    wiring = inject_wiring(
        mode=mode,
        N=_ablation_int_scalar(data, "N"),
        K_rec=_ablation_int_scalar(data, "K_rec"),
        K_in=_ablation_int_scalar(data, "K_in"),
        K=_ablation_int_scalar(data, "K"),
        n_receptors=_ablation_int_scalar(data, "n_receptors"),
        n_effectors=_ablation_int_scalar(data, "n_effectors"),
        dend_source=data["dend_source"],
        node_sources=data["node_sources"],
        receptor_sources=data["receptor_sources"],
        fwd_unit=data["fwd_unit"],
        back_src=data["back_src"],
        R_fwd=data["R_fwd"],
        fwd_count=data["fwd_count"],
        M_ne=data["M_ne"],
    )

    reservoir = CompartmentalReservoir(
        genome,
        wiring;
        substeps=1,   # match the single forward-Euler step (dt=1.0) of the numpy oracle
        hill_tau=Float64(only(data["hill_tau"])),
        hill_reset=Float64(only(data["hill_reset"])),
        intervention=_ablation_intervention(ablation),
    )

    @test pack_params(reservoir.genome) == _ablation_float_vector(data, "raw_variant")
    return reservoir
end

function _assert_ablation_replay(mode::AbstractString, ablation::AbstractString)
    path = _ablation_fixture_path(mode, ablation)
    isfile(path) || error("missing fixture $path; run test/oracle/gen_ablation_fixtures.py from the v0 directory")
    data = npzread(path)

    reservoir = _build_ablation_reservoir(mode, ablation, data)
    inputs = _ablation_float_matrix(data, "inputs")
    dend_y_T = _ablation_float_matrix(data, "dend_y_T")
    soma_y_T = _ablation_float_matrix(data, "soma_y_T")
    V_T = _ablation_float_matrix(data, "V_T")
    spikes_T = _ablation_float_matrix(data, "spikes_T")
    margin_T = _ablation_float_matrix(data, "margin_T")

    @test size(inputs, 1) == size(dend_y_T, 1)

    max_dend = 0.0
    max_soma = 0.0
    max_V = 0.0
    near_margin = 0

    for t in axes(inputs, 1)
        spikes = step!(reservoir, vec(inputs[t, :]))

        dend_dev = _ablation_max_abs_dev(_ablation_flatten_c3(reservoir.dend_y), vec(dend_y_T[t, :]))
        soma_dev = _ablation_max_abs_dev(_ablation_flatten_c2(reservoir.soma_y), vec(soma_y_T[t, :]))
        V_dev = _ablation_max_abs_dev(reservoir.V, vec(V_T[t, :]))

        max_dend = max(max_dend, dend_dev)
        max_soma = max(max_soma, soma_dev)
        max_V = max(max_V, V_dev)

        @test dend_dev <= ABLATION_ATOL
        @test soma_dev <= ABLATION_ATOL
        @test V_dev <= ABLATION_ATOL

        certified = abs.(vec(margin_T[t, :])) .> ABLATION_MARGIN_EPS
        near_margin += count(!, certified)
        expected_spikes = vec(spikes_T[t, :])
        @test spikes[certified] == expected_spikes[certified]
    end

    @info "compartmental ablation oracle parity" mode ablation max_dend max_soma max_V near_margin
end

@testset "Native compartmental wiring" begin
    for mode in (:dense, :structured)
        w = build_wiring(40, 20260628; link_p=0.2, n_receptors=7, n_effectors=3, rho=0.5, mode=mode)
        @test w.N == 40
        @test w.K_rec == min(w.N - 1, max(1, round(Int, 0.2 * (w.N - 1))))
        @test w.K_in == max(1, round(Int, 0.5 * w.K_rec))
        @test w.K == w.K_rec + w.K_in
        @test size(w.dend_source) == (w.N, w.K)
        @test size(w.node_sources) == (w.N, w.K_rec)
        @test size(w.receptor_sources) == (w.N, w.K_in)
        @test all(any(@view w.M_ne[:, eff]) for eff in 1:w.n_effectors)

        for n in 1:w.N
            node_row = vec(w.node_sources[n, :])
            @test length(unique(node_row)) == w.K_rec
            @test all(0 .<= node_row .< w.N)
            @test all(node_row .!= n - 1)
            receptor_row = vec(w.receptor_sources[n, :])
            @test all(0 .<= receptor_row .< w.n_receptors)
        end

        if mode == :structured
            @test w.fwd_unit !== nothing
            @test w.back_src !== nothing
            @test w.R_fwd !== nothing
            @test w.fwd_count !== nothing
            @test all(w.fwd_unit .!= w.back_src)
            @test all(sum(w.R_fwd[n, k, :]) == 1.0 for n in 1:w.N, k in 1:w.K)
            @test all(sum(w.fwd_count[n, :]) == Float64(w.K) for n in 1:w.N)

            cover_len = min(COMPARTMENTAL_S, w.K_in)
            for n in 1:w.N
                covered = vec(w.fwd_unit[n, (w.K_rec + 1):(w.K_rec + cover_len)])
                @test length(unique(covered)) == cover_len
            end
        end
    end

    sim = simulate(:wall; node=:compartmental_structured, ticks=8, seed=11, ablation=:reset_dendrites)
    @test sim isa SimResult
    @test resolve_ablation(:reset_dendrites) === ResetDendrites
    @test resolve_ablation(:no_soma_back) === NoSomaBack
    @test resolve_ablation(:no_hillock_back) === NoHillockBack
end

@testset "Compartmental ablation oracle parity" begin
    for mode in ("dense", "structured")
        normal = npzread(_ablation_fixture_path(mode, "normal"))
        reset = npzread(_ablation_fixture_path(mode, "reset_dendrites"))
        @test any(_ablation_float_matrix(normal, "spikes_T") .!= _ablation_float_matrix(reset, "spikes_T"))

        for ablation in ("normal", "no_soma_back", "no_hillock_back", "reset_dendrites")
            @testset "$mode/$ablation" begin
                _assert_ablation_replay(mode, ablation)
            end
        end
    end
end
