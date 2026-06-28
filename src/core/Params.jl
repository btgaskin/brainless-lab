const TAU_MIN = 1.0

"""
    sigmoid(x)

Numerically stable logistic sigmoid.
"""
function sigmoid(x)
    if x >= 0
        z = exp(-x)
        return inv(1 + z)
    else
        z = exp(x)
        return z / (1 + z)
    end
end

"""
    softplus(x)

Numerically stable softplus transform.
"""
softplus(x) = log1p(exp(-abs(x))) + max(x, zero(x))

"""
    mapped_tau(raw)

Map an unconstrained raw value to a positive time constant.
"""
mapped_tau(raw) = TAU_MIN + softplus(raw)
