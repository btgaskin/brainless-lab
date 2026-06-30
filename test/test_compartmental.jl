using BrainlessLab
using NPZ
using Test

const COMPARTMENTAL_ATOL = 1e-9
const COMPARTMENTAL_MARGIN_EPS = 1e-6

function _compartmental_fixture_path(mode)
    return joinpath(@__DIR__, "fixtures", "compartmental_$(mode).npz")
end

function _int_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Int(value) : Int(only(value))
end

function _float_matrix_fixture(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _float_vector_fixture(data, key::AbstractString)
    return Vector{Float64}(vec(Float64.(data[key])))
end

function _flatten_c2(x::AbstractMatrix{<:Real})
    out = Vector{Float64}(undef, size(x, 1) * size(x, 2))
    idx = 1
    @inbounds for i in axes(x, 1), j in axes(x, 2)
        out[idx] = Float64(x[i, j])
        idx += 1
    end
    return out
end

function _flatten_c3(x::Array{<:Real,3})
    out = Vector{Float64}(undef, size(x, 1) * size(x, 2) * size(x, 3))
    idx = 1
    @inbounds for i in axes(x, 1), j in axes(x, 2), k in axes(x, 3)
        out[idx] = Float64(x[i, j, k])
        idx += 1
    end
    return out
end

function _max_abs_dev(a::AbstractVector{<:Real}, b::AbstractVector{<:Real})
    length(a) == length(b) || throw(DimensionMismatch("lengths $(length(a)) and $(length(b)) differ"))
    return isempty(a) ? 0.0 : maximum(abs.(Float64.(a) .- Float64.(b)))
end

function _build_compartmental(mode::AbstractString, data)
    raw = _float_vector_fixture(data, "raw")
    genome =
        mode == "dense" ?
        unpack_params(DenseCompartmental, raw) :
        unpack_params(StructuredCompartmental, raw)

    @test pack_params(genome) == raw

    wiring = inject_wiring(
        mode=mode,
        N=_int_scalar(data, "N"),
        K_rec=_int_scalar(data, "K_rec"),
        K_in=_int_scalar(data, "K_in"),
        K=_int_scalar(data, "K"),
        n_receptors=_int_scalar(data, "n_receptors"),
        n_effectors=_int_scalar(data, "n_effectors"),
        dend_source=data["dend_source"],
        node_sources=data["node_sources"],
        receptor_sources=data["receptor_sources"],
        fwd_unit=data["fwd_unit"],
        back_src=data["back_src"],
        R_fwd=data["R_fwd"],
        fwd_count=data["fwd_count"],
        M_ne=data["M_ne"],
    )

    return CompartmentalReservoir(
        genome,
        wiring;
        substeps=1,   # match the single forward-Euler step (dt=1.0) of the numpy oracle
        hill_tau=Float64(only(data["hill_tau"])),
        hill_reset=Float64(only(data["hill_reset"])),
    )
end

function _assert_compartmental_replay(mode)
    path = _compartmental_fixture_path(mode)
    isfile(path) || error("missing fixture $path; run test/oracle/gen_compartmental_fixtures.py from the v0 directory")
    data = npzread(path)

    reservoir = _build_compartmental(mode, data)
    inputs = _float_matrix_fixture(data, "inputs")
    dend_y_T = _float_matrix_fixture(data, "dend_y_T")
    soma_y_T = _float_matrix_fixture(data, "soma_y_T")
    V_T = _float_matrix_fixture(data, "V_T")
    spikes_T = _float_matrix_fixture(data, "spikes_T")
    margin_T = _float_matrix_fixture(data, "margin_T")

    @test size(inputs, 1) == size(dend_y_T, 1)
    @test sum(spikes_T) > 0.0

    max_dend = 0.0
    max_soma = 0.0
    max_V = 0.0
    near_margin = 0

    for t in axes(inputs, 1)
        spikes = step!(reservoir, vec(inputs[t, :]))

        dend_dev = _max_abs_dev(_flatten_c3(reservoir.dend_y), vec(dend_y_T[t, :]))
        soma_dev = _max_abs_dev(_flatten_c2(reservoir.soma_y), vec(soma_y_T[t, :]))
        V_dev = _max_abs_dev(reservoir.V, vec(V_T[t, :]))

        max_dend = max(max_dend, dend_dev)
        max_soma = max(max_soma, soma_dev)
        max_V = max(max_V, V_dev)

        @test dend_dev <= COMPARTMENTAL_ATOL
        @test soma_dev <= COMPARTMENTAL_ATOL
        @test V_dev <= COMPARTMENTAL_ATOL

        certified = abs.(vec(margin_T[t, :])) .> COMPARTMENTAL_MARGIN_EPS
        near_margin += count(!, certified)
        expected_spikes = vec(spikes_T[t, :])
        @test spikes[certified] == expected_spikes[certified]
    end

    @info "compartmental oracle parity" mode max_dend max_soma max_V near_margin
end

@testset "Compartmental oracle parity" begin
    for mode in ("dense", "structured")
        @testset "$mode" begin
            _assert_compartmental_replay(mode)
        end
    end
end
