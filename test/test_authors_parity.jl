using BrainlessLab
using JLD2
using Test

const AUTHORS_FALANDAYS_ATOL = 1e-9

function _authors_fixture_path(task::Symbol)
    return joinpath(@__DIR__, "fixtures", "authors_$(task).jld2")
end

function _authors_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function _authors_int(data, key::AbstractString)
    return Int(round(_authors_scalar(data, key)))
end

function _authors_matrix(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _authors_bitmatrix(data, key::AbstractString)
    raw = data[key]
    mask = falses(size(raw, 1), size(raw, 2))
    @inbounds for j in axes(mask, 2), i in axes(mask, 1)
        mask[i, j] = raw[i, j] != 0
    end
    return mask
end

function _authors_params(data)
    return FalandaysParams(
        leak=_authors_scalar(data, "leak"),
        lrate_wmat=_authors_scalar(data, "lrate_wmat"),
        lrate_targ=_authors_scalar(data, "lrate_targ"),
        threshold_mult=2.0,
        targ_min=_authors_scalar(data, "targ_min"),
        input_weight=_authors_scalar(data, "input_amp"),
        weight_init_std=1.0,
        learn_on=true,
    )
end

function _authors_reservoir(data)
    ticks = _authors_int(data, "ticks")
    n_nodes = _authors_int(data, "nnodes")
    return FalandaysReservoir(
        params=_authors_params(data),
        drive=NoDrive(),
        sign=BrainlessLab.Unsigned(),
        recurrent_mask=_authors_bitmatrix(data, "recurrent_mask"),
        input_wmat=_authors_matrix(data, "input_wmat"),
        output_mask=_authors_matrix(data, "output_mask"),
        wmat0=_authors_matrix(data, "wmat0"),
        noise_source=RecordedNoise(zeros(Float64, ticks, n_nodes)),
        rectify=false,
    )
end

function _authors_max_abs_dev(a, b)
    av = Float64.(vec(a))
    bv = Float64.(vec(b))
    length(av) == length(bv) ||
        throw(DimensionMismatch("lengths $(length(av)) and $(length(bv)) differ"))
    isempty(av) && return 0.0
    return maximum(abs.(av .- bv))
end

function _assert_authors_replay(task::Symbol)
    path = _authors_fixture_path(task)
    isfile(path) || error("missing fixture $path; run test/oracle/authors_falandays.jl")
    data = JLD2.load(path)
    reservoir = _authors_reservoir(data)

    inputs = _authors_matrix(data, "inputs")
    acts_T = _authors_matrix(data, "acts_T")
    targets_T = _authors_matrix(data, "targets_T")
    spikes_T = _authors_matrix(data, "spikes_T")
    errors_T = _authors_matrix(data, "errors_T")

    max_act = 0.0
    max_target = 0.0
    max_spike = 0.0
    max_error = 0.0

    for t in axes(inputs, 1)
        spikes = step!(reservoir, vec(inputs[t, :]))
        max_act = max(max_act, _authors_max_abs_dev(reservoir.acts, acts_T[t, :]))
        max_target = max(max_target, _authors_max_abs_dev(reservoir.targets, targets_T[t, :]))
        max_spike = max(max_spike, _authors_max_abs_dev(spikes, spikes_T[t, :]))
        max_error = max(max_error, _authors_max_abs_dev(reservoir.errors, errors_T[t, :]))
    end

    @test max_act <= AUTHORS_FALANDAYS_ATOL
    @test max_target <= AUTHORS_FALANDAYS_ATOL
    @test max_spike <= AUTHORS_FALANDAYS_ATOL
    @test max_error <= AUTHORS_FALANDAYS_ATOL
    @test _authors_max_abs_dev(reservoir.wmat, data["wmat_final"]) <= AUTHORS_FALANDAYS_ATOL
end

@testset "Authors Falandays trajectory parity" begin
    for task in (:wall, :tracking, :pong)
        @testset "$(task)" begin
            _assert_authors_replay(task)
        end
    end
end
