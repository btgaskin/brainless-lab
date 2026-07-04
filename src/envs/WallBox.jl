using Random

mutable struct RecordedDraws
    values::Vector{Float64}
    index::Int
end

RecordedDraws(values::AbstractVector{<:Real}) = RecordedDraws(Float64.(vec(values)), 1)

function recorded_draw!(src::RecordedDraws, k::Integer=1)
    k < 0 && throw(ArgumentError("draw size must be non-negative"))
    last = src.index + k - 1
    last <= length(src.values) ||
        throw(ArgumentError("RecordedDraws exhausted at draw $(src.index); requested $k values"))
    out = src.values[src.index:last]
    src.index = last + 1
    return k == 1 ? out[1] : out
end

draws_remaining(src::RecordedDraws) = length(src.values) - src.index + 1

function reset!(src::RecordedDraws)
    src.index = 1
    return src
end

_rng_uniform(src::RecordedDraws, lo::Real, hi::Real) = Float64(recorded_draw!(src))
_rng_uniform(rng::AbstractRNG, lo::Real, hi::Real) = Float64(lo) + (Float64(hi) - Float64(lo)) * rand(rng)

_rng_choice_pm1(src::RecordedDraws) = Float64(recorded_draw!(src))
_rng_choice_pm1(rng::AbstractRNG) = rand(rng, Bool) ? 1.0 : -1.0

function _wrap_angle(theta::Real)
    wrapped = mod(Float64(theta) + pi, 2.0 * pi) - pi
    if wrapped <= -pi
        wrapped += 2.0 * pi
    end
    return wrapped
end

mutable struct WallBox{R}
    rng::R
    size::Float64
    r::Float64
    dt::Float64
    eps::Float64
    x::Float64
    y::Float64
    theta::Float64
    dist_max::Float64
    collisions::Int
    distance::Float64
    poses::Vector{NTuple{3,Float64}}
    collision_flags::Vector{Int}
    translations::Vector{Float64}
end

function WallBox(;
    rng=Random.default_rng(),
    x=nothing,
    y=nothing,
    theta=nothing,
    size::Real=15.0,
    r::Real=0.5,
    dt::Real=1.0,
    eps::Real=1e-6,
)
    size_f = Float64(size)
    r_f = Float64(r)
    lo = r_f
    hi = size_f - r_f

    x0 = x === nothing ? _rng_uniform(rng, lo, hi) : Float64(x)
    y0 = y === nothing ? _rng_uniform(rng, lo, hi) : Float64(y)
    raw_theta = theta === nothing ? _rng_uniform(rng, -pi, pi) : Float64(theta)
    theta0 = _wrap_angle(raw_theta)

    if !(lo <= x0 <= hi && lo <= y0 <= hi)
        throw(ArgumentError("start pose must keep the agent circle inside the box"))
    end

    return WallBox(
        rng,
        size_f,
        r_f,
        Float64(dt),
        Float64(eps),
        x0,
        y0,
        theta0,
        sqrt(2.0 * size_f^2),
        0,
        0.0,
        NTuple{3,Float64}[],
        Int[],
        Float64[],
    )
end

WallBox(seed::Integer; kwargs...) = WallBox(; rng=MersenneTwister(seed), kwargs...)

function reset!(box::WallBox; x=nothing, y=nothing, theta=nothing)
    lo = box.r
    hi = box.size - box.r
    x0 = x === nothing ? _rng_uniform(box.rng, lo, hi) : Float64(x)
    y0 = y === nothing ? _rng_uniform(box.rng, lo, hi) : Float64(y)
    raw_theta = theta === nothing ? _rng_uniform(box.rng, -pi, pi) : Float64(theta)
    theta0 = _wrap_angle(raw_theta)

    if !(lo <= x0 <= hi && lo <= y0 <= hi)
        throw(ArgumentError("start pose must keep the agent circle inside the box"))
    end

    box.x = x0
    box.y = y0
    box.theta = theta0
    box.collisions = 0
    box.distance = 0.0
    empty!(box.poses)
    empty!(box.collision_flags)
    empty!(box.translations)
    return box
end

function _ray_distance(box::WallBox, angle::Real)
    dx = cos(Float64(angle))
    dy = sin(Float64(angle))
    candidates = Float64[]
    tol = 1e-12

    if abs(dx) > tol
        for wall_x in (0.0, box.size)
            t = (wall_x - box.x) / dx
            if t > 0.0
                y_hit = box.y + t * dy
                if -tol <= y_hit <= box.size + tol
                    push!(candidates, Float64(t))
                end
            end
        end
    end

    if abs(dy) > tol
        for wall_y in (0.0, box.size)
            t = (wall_y - box.y) / dy
            if t > 0.0
                x_hit = box.x + t * dx
                if -tol <= x_hit <= box.size + tol
                    push!(candidates, Float64(t))
                end
            end
        end
    end

    isempty(candidates) && error("a ray from inside a closed box must hit a wall")
    return minimum(candidates)
end

function sense(box::WallBox)
    d_left = _ray_distance(box, box.theta + pi / 4.0)
    d_right = _ray_distance(box, box.theta - pi / 4.0)
    c_left = 1.0 - d_left / box.dist_max
    c_right = 1.0 - d_right / box.dist_max
    return [
        min(1.0, max(box.eps, c_left)),
        min(1.0, max(box.eps, c_right)),
    ]
end

function step!(box::WallBox, e_L::Real, e_R::Real)
    eL = clamp(Float64(e_L), 0.0, 1.0)
    eR = clamp(Float64(e_R), 0.0, 1.0)
    x0 = box.x
    y0 = box.y
    theta0 = box.theta

    v = (eL + eR) / 2.0
    theta1 = _wrap_angle(theta0 + (eR - eL))
    x1 = x0 + v * cos(theta1)
    y1 = y0 + v * sin(theta1)

    hit = x1 < box.r || x1 > box.size - box.r || y1 < box.r || y1 > box.size - box.r
    if hit
        box.theta = _wrap_angle(theta0 + _rng_choice_pm1(box.rng) * pi / 4.0)
        box.collisions += 1
        translation = 0.0
        collision_flag = 1
    else
        box.x = Float64(x1)
        box.y = Float64(y1)
        box.theta = theta1
        translation = Float64(hypot(box.x - x0, box.y - y0))
        box.distance += translation
        collision_flag = 0
    end

    push!(box.poses, (box.x, box.y, box.theta))
    push!(box.collision_flags, collision_flag)
    push!(box.translations, translation)
    return box
end

function distance_last(box::WallBox, n::Integer)
    n <= 0 && return 0.0
    last_n = min(Int(n), length(box.translations))
    last_n == 0 && return 0.0
    first_i = length(box.translations) - last_n + 1
    return Float64(sum(@view box.translations[first_i:end]))
end

function collisions_last(box::WallBox, n::Integer)
    n <= 0 && return 0
    last_n = min(Int(n), length(box.collision_flags))
    last_n == 0 && return 0
    first_i = length(box.collision_flags) - last_n + 1
    return Int(sum(@view box.collision_flags[first_i:end]))
end

function metrics(box::WallBox)
    return (
        ticks=length(box.translations),
        pose=(box.x, box.y, box.theta),
        collisions=box.collisions,
        distance=box.distance,
        collisions_last_200=collisions_last(box, 200),
        distance_last_200=distance_last(box, 200),
    )
end
