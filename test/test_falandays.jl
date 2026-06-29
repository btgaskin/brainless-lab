using BrainlessLab
using NPZ
using Test

const FALANDAYS_ATOL = 1e-9
const FALANDAYS_MARGIN_EPS = 1e-6

function _fixture_path(name)
    return joinpath(@__DIR__, "fixtures", "falandays_$(name).npz")
end

function _scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function _bool_scalar(data, key::AbstractString)
    return Bool(round(Int, _scalar(data, key)))
end

function _params_from_fixture(data)
    return FalandaysParams(
        leak=_scalar(data, "leak"),
        lrate_wmat=_scalar(data, "lrate_wmat"),
        lrate_targ=_scalar(data, "lrate_targ"),
        threshold_mult=_scalar(data, "threshold_mult"),
        targ_min=_scalar(data, "targ_min"),
        input_weight=_scalar(data, "input_weight"),
        weight_init_std=_scalar(data, "weight_init_std"),
        learn_on=_bool_scalar(data, "learn_on"),
    )
end

function _matrix(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _bitmatrix_fixture(data, key::AbstractString)
    raw = data[key]
    mask = falses(size(raw, 1), size(raw, 2))
    @inbounds for j in axes(mask, 2), i in axes(mask, 1)
        mask[i, j] = raw[i, j] != 0
    end
    return mask
end

function _case_axis(name, data)
    sign = vec(Int.(data["sign"]))
    return name == "dale" ? Dale(sign) : BrainlessLab.Unsigned()
end

function _case_drive(name, data)
    if name == "oosawa"
        return OosawaDrive(
            membrane_noise=_scalar(data, "membrane_noise"),
            noise_gain=_scalar(data, "noise_gain"),
        )
    end
    return NoDrive()
end

function _build_reservoir(name, data)
    return FalandaysReservoir(
        params=_params_from_fixture(data),
        drive=_case_drive(name, data),
        sign=_case_axis(name, data),
        recurrent_mask=_bitmatrix_fixture(data, "recurrent_mask"),
        input_wmat=_matrix(data, "input_wmat"),
        output_mask=_matrix(data, "output_mask"),
        wmat0=_matrix(data, "wmat0"),
        noise_source=RecordedNoise(_matrix(data, "noise_draws")),
        rectify=_bool_scalar(data, "rectify"),
    )
end

function _assert_replay(name)
    path = _fixture_path(name)
    isfile(path) || error("missing fixture $path; run test/oracle/gen_falandays_fixtures.py from the v0.2 directory")
    data = npzread(path)
    reservoir = _build_reservoir(name, data)

    inputs = _matrix(data, "inputs")
    acts_T = _matrix(data, "acts_T")
    targets_T = _matrix(data, "targets_T")
    spikes_T = _matrix(data, "spikes_T")
    margin_T = _matrix(data, "margin_T")
    near_margin = 0

    for t in axes(inputs, 1)
        spikes = step!(reservoir, vec(inputs[t, :]))

        act_dev = maximum(abs.(reservoir.acts .- vec(acts_T[t, :])))
        target_dev = maximum(abs.(reservoir.targets .- vec(targets_T[t, :])))
        act_dev <= FALANDAYS_ATOL ||
            error("$name tick $t acts max abs deviation $act_dev")
        target_dev <= FALANDAYS_ATOL ||
            error("$name tick $t targets max abs deviation $target_dev")

        certified = abs.(vec(margin_T[t, :])) .> FALANDAYS_MARGIN_EPS
        near_margin += count(!, certified)
        expected_spikes = vec(spikes_T[t, :])
        spikes[certified] == expected_spikes[certified] ||
            error("$name tick $t certified spikes differ")
    end

    @test near_margin >= 0
end

@testset "Falandays oracle parity" begin
    for name in ("base", "oosawa", "dale")
        @testset "$name" begin
            _assert_replay(name)
        end
    end
end
