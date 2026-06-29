"""
    Torus(size)

Square torus geometry matching the v0.2 CRHO helpers.
"""
struct Torus
    size::Float64

    function Torus(size::Real)
        size_ = Float64(size)
        size_ > 0.0 || throw(ArgumentError("torus size must be positive"))
        return new(size_)
    end
end

wrap(t::Torus, x::Real, y::Real) = (mod(Float64(x), t.size), mod(Float64(y), t.size))
wrap(t::Torus, p) = wrap(t, p[1], p[2])

function tdelta(t::Torus, a, b)
    half = 0.5 * t.size
    dx = mod(Float64(b[1]) - Float64(a[1]) + half, t.size) - half
    dy = mod(Float64(b[2]) - Float64(a[2]) + half, t.size) - half
    return (dx, dy)
end

function tdistance(t::Torus, a, b)
    dx, dy = tdelta(t, a, b)
    return Float64(hypot(dx, dy))
end

function bearing(t::Torus, a, b)
    dx, dy = tdelta(t, a, b)
    return Float64(atan(dy, dx))
end

max_dist(t::Torus) = Float64(sqrt(2.0) * t.size / 2.0)
