abstract type AbstractCompartmental <: NodeModel end

const COMPARTMENTAL_D = 6
const COMPARTMENTAL_S = 12
const D = COMPARTMENTAL_D
const S = COMPARTMENTAL_S

const IN_UNIT = 0
const OUT_UNIT = 1
const FB_UNIT = 2

const DRIVE_UNIT = 0
const THR_UNIT = 1
const HB_UNIT = 2

const HILL_TAU = 3.5
const HILL_RESET = 0.0

const COMPARTMENTAL_DENSE_PARAM_DIM = 404
const COMPARTMENTAL_STRUCTURED_PARAM_DIM = 220

struct DenseCompartmental <: AbstractCompartmental
    w_aff_d::Vector{Float64}
    W_dd::Matrix{Float64}
    W_s_d::Matrix{Float64}
    W_d_s::Matrix{Float64}
    W_ss::Matrix{Float64}
    b_d::Vector{Float64}
    raw_tau_d::Vector{Float64}
    tau_d::Vector{Float64}
    b_s::Vector{Float64}
    raw_tau_s::Vector{Float64}
    tau_s::Vector{Float64}
    w_s_drv::Vector{Float64}
    w_s_thr::Vector{Float64}
    w_h_s::Vector{Float64}
    thr_base::Float64
    thr_gain::Float64
end

struct StructuredCompartmental <: AbstractCompartmental
    w_aff::Float64
    W_dd::Matrix{Float64}
    w_back::Float64
    W_ss::Matrix{Float64}
    b_d::Vector{Float64}
    raw_tau_d::Vector{Float64}
    tau_d::Vector{Float64}
    b_s::Vector{Float64}
    raw_tau_s::Vector{Float64}
    tau_s::Vector{Float64}
    w_drv::Float64
    w_hb::Float64
end

const _DENSE_COMPARTMENTAL_SCHEMA = (
    (:w_aff_d, (COMPARTMENTAL_D,)),
    (:W_dd, (COMPARTMENTAL_D, COMPARTMENTAL_D)),
    (:W_s_d, (COMPARTMENTAL_S, COMPARTMENTAL_D)),
    (:W_d_s, (COMPARTMENTAL_D, COMPARTMENTAL_S)),
    (:W_ss, (COMPARTMENTAL_S, COMPARTMENTAL_S)),
    (:b_d, (COMPARTMENTAL_D,)),
    (:raw_tau_d, (COMPARTMENTAL_D,)),
    (:b_s, (COMPARTMENTAL_S,)),
    (:raw_tau_s, (COMPARTMENTAL_S,)),
    (:w_s_drv, (COMPARTMENTAL_S,)),
    (:w_s_thr, (COMPARTMENTAL_S,)),
    (:w_h_s, (COMPARTMENTAL_S,)),
    (:thr_base, (1,)),
    (:thr_gain, (1,)),
)

const _STRUCTURED_COMPARTMENTAL_SCHEMA = (
    (:w_aff, (1,)),
    (:W_dd, (COMPARTMENTAL_D, COMPARTMENTAL_D)),
    (:w_back, (1,)),
    (:W_ss, (COMPARTMENTAL_S, COMPARTMENTAL_S)),
    (:b_d, (COMPARTMENTAL_D,)),
    (:raw_tau_d, (COMPARTMENTAL_D,)),
    (:b_s, (COMPARTMENTAL_S,)),
    (:raw_tau_s, (COMPARTMENTAL_S,)),
    (:w_drv, (1,)),
    (:w_hb, (1,)),
)

_compartmental_schema(::Type{DenseCompartmental}) = _DENSE_COMPARTMENTAL_SCHEMA
_compartmental_schema(::Type{StructuredCompartmental}) = _STRUCTURED_COMPARTMENTAL_SCHEMA
_compartmental_schema(::DenseCompartmental) = _DENSE_COMPARTMENTAL_SCHEMA
_compartmental_schema(::StructuredCompartmental) = _STRUCTURED_COMPARTMENTAL_SCHEMA

_compartmental_mode(::DenseCompartmental) = :dense
_compartmental_mode(::StructuredCompartmental) = :structured
_compartmental_mode(::Type{DenseCompartmental}) = :dense
_compartmental_mode(::Type{StructuredCompartmental}) = :structured

paramdim(::Type{DenseCompartmental}) = COMPARTMENTAL_DENSE_PARAM_DIM
paramdim(::DenseCompartmental) = COMPARTMENTAL_DENSE_PARAM_DIM
paramdim(::Type{StructuredCompartmental}) = COMPARTMENTAL_STRUCTURED_PARAM_DIM
paramdim(::StructuredCompartmental) = COMPARTMENTAL_STRUCTURED_PARAM_DIM

_compartmental_shape_length(shape::Tuple) = prod(shape)

function _compartmental_sigmoid(x::Real)
    z = clamp(Float64(x), -60.0, 60.0)
    return inv(1.0 + exp(-z))
end

function _compartmental_float_vector(x, name::AbstractString)
    v = vec(Float64.(x))
    return Vector{Float64}(v)
end

function _compartmental_reshape_c(vals::AbstractVector{Float64}, shape::Tuple{Int})
    length(vals) == shape[1] ||
        throw(DimensionMismatch("cannot reshape $(length(vals)) values to $shape"))
    return copy(vals)
end

function _compartmental_reshape_c(vals::AbstractVector{Float64}, shape::Tuple{Int,Int})
    rows, cols = shape
    length(vals) == rows * cols ||
        throw(DimensionMismatch("cannot reshape $(length(vals)) values to $shape"))

    out = Matrix{Float64}(undef, rows, cols)
    idx = 1
    @inbounds for i in 1:rows, j in 1:cols
        out[i, j] = vals[idx]
        idx += 1
    end
    return out
end

function _compartmental_unpack_fields(::Type{T}, raw::AbstractVector{<:Real}) where {T<:AbstractCompartmental}
    raw64 = Vector{Float64}(Float64.(raw))
    expected = paramdim(T)
    length(raw64) == expected ||
        throw(ArgumentError("expected raw vector of length $expected for $(T), got $(length(raw64))"))

    fields = Dict{Symbol,Any}()
    i = 1
    for (name, shape) in _compartmental_schema(T)
        k = _compartmental_shape_length(shape)
        fields[name] = _compartmental_reshape_c(raw64[i:(i + k - 1)], shape)
        i += k
    end
    return fields
end

function unpack_params(::Type{DenseCompartmental}, raw::AbstractVector{<:Real})::DenseCompartmental
    f = _compartmental_unpack_fields(DenseCompartmental, raw)
    raw_tau_d = f[:raw_tau_d]
    raw_tau_s = f[:raw_tau_s]

    return DenseCompartmental(
        f[:w_aff_d],
        f[:W_dd],
        f[:W_s_d],
        f[:W_d_s],
        f[:W_ss],
        f[:b_d],
        raw_tau_d,
        TAU_MIN .+ softplus.(raw_tau_d),
        f[:b_s],
        raw_tau_s,
        TAU_MIN .+ softplus.(raw_tau_s),
        f[:w_s_drv],
        f[:w_s_thr],
        f[:w_h_s],
        Float64(f[:thr_base][1]),
        Float64(f[:thr_gain][1]),
    )
end

function unpack_params(::Type{StructuredCompartmental}, raw::AbstractVector{<:Real})::StructuredCompartmental
    f = _compartmental_unpack_fields(StructuredCompartmental, raw)
    raw_tau_d = f[:raw_tau_d]
    raw_tau_s = f[:raw_tau_s]

    return StructuredCompartmental(
        Float64(f[:w_aff][1]),
        f[:W_dd],
        Float64(f[:w_back][1]),
        f[:W_ss],
        f[:b_d],
        raw_tau_d,
        TAU_MIN .+ softplus.(raw_tau_d),
        f[:b_s],
        raw_tau_s,
        TAU_MIN .+ softplus.(raw_tau_s),
        Float64(f[:w_drv][1]),
        Float64(f[:w_hb][1]),
    )
end

function _compartmental_pack_value!(out::Vector{Float64}, x::AbstractVector{<:Real})
    append!(out, Float64.(x))
    return out
end

function _compartmental_pack_value!(out::Vector{Float64}, x::AbstractMatrix{<:Real})
    @inbounds for i in axes(x, 1), j in axes(x, 2)
        push!(out, Float64(x[i, j]))
    end
    return out
end

function _compartmental_pack_value!(out::Vector{Float64}, x::Real)
    push!(out, Float64(x))
    return out
end

function pack_params(g::DenseCompartmental)
    out = Float64[]
    sizehint!(out, COMPARTMENTAL_DENSE_PARAM_DIM)
    for (name, _) in _DENSE_COMPARTMENTAL_SCHEMA
        _compartmental_pack_value!(out, getfield(g, name))
    end
    return out
end

function pack_params(g::StructuredCompartmental)
    out = Float64[]
    sizehint!(out, COMPARTMENTAL_STRUCTURED_PARAM_DIM)
    for (name, _) in _STRUCTURED_COMPARTMENTAL_SCHEMA
        _compartmental_pack_value!(out, getfield(g, name))
    end
    return out
end
