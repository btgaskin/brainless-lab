"""
    ResponseCurve

Abstract contract for normalized scalar response curves. Curves accept and
return values in `[0, 1]`; callers remain responsible for applying any external
gain after the response has been shaped.
"""
abstract type ResponseCurve end

struct ConstantResponse <: ResponseCurve
    value::Float64

    function ConstantResponse(value::Real=1.0)
        value_ = Float64(value)
        isfinite(value_) && 0.0 <= value_ <= 1.0 ||
            throw(ArgumentError("constant response must lie in [0, 1]"))
        return new(value_)
    end
end

struct LinearResponse <: ResponseCurve end

struct PowerResponse <: ResponseCurve
    exponent::Float64

    function PowerResponse(exponent::Real=1.0)
        exponent_ = Float64(exponent)
        isfinite(exponent_) && exponent_ > 0.0 ||
            throw(ArgumentError("response exponent must be finite and positive"))
        return new(exponent_)
    end
end

struct LogisticResponse <: ResponseCurve
    slope::Float64
    midpoint::Float64

    function LogisticResponse(slope::Real=10.0, midpoint::Real=0.5)
        slope_ = Float64(slope)
        midpoint_ = Float64(midpoint)
        isfinite(slope_) && slope_ > 0.0 ||
            throw(ArgumentError("logistic slope must be finite and positive"))
        isfinite(midpoint_) && 0.0 <= midpoint_ <= 1.0 ||
            throw(ArgumentError("logistic midpoint must lie in [0, 1]"))
        return new(slope_, midpoint_)
    end
end

struct ThresholdResponse <: ResponseCurve
    threshold::Float64

    function ThresholdResponse(threshold::Real=0.5)
        threshold_ = Float64(threshold)
        isfinite(threshold_) && 0.0 <= threshold_ <= 1.0 ||
            throw(ArgumentError("response threshold must lie in [0, 1]"))
        return new(threshold_)
    end
end

@inline (curve::ConstantResponse)(x::Real) = (_response_input(x); curve.value)
@inline (::LinearResponse)(x::Real) = _response_input(x)
@inline (curve::PowerResponse)(x::Real) = _response_input(x)^curve.exponent
@inline (curve::ThresholdResponse)(x::Real) = _response_input(x) >= curve.threshold ? 1.0 : 0.0

@inline function _stable_logistic(value::Float64)
    if value >= 0.0
        return inv(1.0 + exp(-value))
    end
    exponential = exp(value)
    return exponential / (1.0 + exponential)
end

@inline function (curve::LogisticResponse)(x::Real)
    value = _response_input(x)
    lo = _stable_logistic(-curve.slope * curve.midpoint)
    hi = _stable_logistic(curve.slope * (1.0 - curve.midpoint))
    denominator = hi - lo
    denominator <= eps(Float64) && return value
    at = _stable_logistic(curve.slope * (value - curve.midpoint))
    return Float64((at - lo) / denominator)
end

@inline function _response_input(x::Real)
    value = Float64(x)
    isfinite(value) || throw(ArgumentError("response input must be finite"))
    0.0 <= value <= 1.0 ||
        throw(ArgumentError("response input must lie in [0, 1], got $(value)"))
    return value
end

"""Evaluate a normalized response curve, including user-supplied callables."""
@inline function response_value(curve, x::Real)
    input = _response_input(x)
    value = Float64(curve(input))
    isfinite(value) || throw(ArgumentError("response curve returned a non-finite value"))
    0.0 <= value <= 1.0 || throw(ArgumentError(
        "response curve output must lie in [0, 1], got $(value)",
    ))
    return value
end

# Compatibility names retained for the physiology API introduced on this branch.
const LinearFeedback = LinearResponse
const PowerFeedback = PowerResponse
const LogisticFeedback = LogisticResponse
const ThresholdFeedback = ThresholdResponse
