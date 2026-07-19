using StaticArrays: SVector
using LinearAlgebra: dot

"""A validated, arbitrary-resolution wavelength grid in nanometres."""
struct SpectralGrid
    wavelengths_nm::Vector{Float64}

    function SpectralGrid(wavelengths_nm)
        wavelengths = Float64.(vec(collect(wavelengths_nm)))
        length(wavelengths) >= 2 ||
            throw(ArgumentError("a spectral grid needs at least two wavelengths"))
        all(isfinite, wavelengths) ||
            throw(ArgumentError("spectral-grid wavelengths must be finite"))
        all(>(0.0), wavelengths) ||
            throw(ArgumentError("spectral-grid wavelengths must be positive"))
        all(i -> wavelengths[i] < wavelengths[i + 1], 1:(length(wavelengths) - 1)) ||
            throw(ArgumentError("spectral-grid wavelengths must be strictly increasing"))
        return new(wavelengths)
    end
end

Base.length(grid::SpectralGrid) = length(grid.wavelengths_nm)
Base.:(==)(a::SpectralGrid, b::SpectralGrid) = a.wavelengths_nm == b.wavelengths_nm

function _require_grid_match(expected::SpectralGrid, actual::SpectralGrid, label::AbstractString)
    expected == actual || throw(DimensionMismatch(
        "$(label) uses a spectral grid incompatible with the camera/illuminant grid",
    ))
    return nothing
end

function _spectral_values(grid::SpectralGrid, values, label::AbstractString)
    out = Float64.(vec(collect(values)))
    length(out) == length(grid) || throw(DimensionMismatch(
        "$(label) has $(length(out)) values; expected $(length(grid))",
    ))
    all(isfinite, out) || throw(ArgumentError("$(label) values must be finite"))
    return out
end

"""A finite, non-negative spectral signal on a [`SpectralGrid`](@ref)."""
struct Spectrum
    grid::SpectralGrid
    values::Vector{Float64}

    function Spectrum(grid::SpectralGrid, values)
        out = _spectral_values(grid, values, "spectrum")
        all(>=(0.0), out) || throw(ArgumentError("spectrum values must be non-negative"))
        return new(grid, out)
    end
end

"""A spectral reflectance constrained to the physical interval `[0, 1]`."""
struct SpectralReflectance
    grid::SpectralGrid
    values::Vector{Float64}

    function SpectralReflectance(grid::SpectralGrid, values)
        out = _spectral_values(grid, values, "spectral reflectance")
        all(value -> 0.0 <= value <= 1.0, out) ||
            throw(ArgumentError("spectral reflectance values must lie in [0, 1]"))
        return new(grid, out)
    end
end

"""Optical object appearance represented by a validated spectral reflectance."""
struct SpectralAppearance <: AbstractObjectAppearance
    reflectance::SpectralReflectance
end

spectral_reflectance(appearance::SpectralAppearance) = appearance.reflectance
_same_object_appearance(a::SpectralAppearance, b::SpectralAppearance) =
    a.reflectance.grid == b.reflectance.grid &&
    a.reflectance.values == b.reflectance.values

"""
    rgb_appearance(rgb; grid=SpectralGrid(350:10:750))

Construct a convenient approximate reflectance tag from a linear RGB triple in
`[0, 1]`. This is a compact scene-authoring helper, not an inverse-colourimetry
or material-calibration routine; experiments needing measured spectra should
construct `SpectralReflectance` directly.
"""
function rgb_appearance(
    rgb;
    grid::SpectralGrid=SpectralGrid(collect(350.0:10.0:750.0)),
)
    values = Float64.(vec(collect(rgb)))
    length(values) == 3 || throw(DimensionMismatch(
        "RGB appearance requires exactly three channel values",
    ))
    all(value -> isfinite(value) && 0.0 <= value <= 1.0, values) ||
        throw(ArgumentError("RGB appearance values must lie in [0, 1]"))
    red, green, blue = values
    reflectance = map(grid.wavelengths_nm) do wavelength
        r = red * exp(-0.5 * ((wavelength - 610.0) / 45.0)^2)
        g = green * exp(-0.5 * ((wavelength - 545.0) / 38.0)^2)
        b = blue * exp(-0.5 * ((wavelength - 455.0) / 32.0)^2)
        clamp(r + g + b, 0.0, 1.0)
    end
    return SpectralAppearance(SpectralReflectance(grid, reflectance))
end

"""A finite, non-negative relative spectral illuminant."""
struct SpectralIlluminant
    grid::SpectralGrid
    values::Vector{Float64}

    function SpectralIlluminant(grid::SpectralGrid, values)
        out = _spectral_values(grid, values, "spectral illuminant")
        all(>=(0.0), out) ||
            throw(ArgumentError("spectral illuminant values must be non-negative"))
        return new(grid, out)
    end
end

function _trapezoid_weights(grid::SpectralGrid)
    wavelengths = grid.wavelengths_nm
    n = length(wavelengths)
    weights = Vector{Float64}(undef, n)
    weights[1] = (wavelengths[2] - wavelengths[1]) / 2.0
    @inbounds for i in 2:(n - 1)
        weights[i] = (wavelengths[i + 1] - wavelengths[i - 1]) / 2.0
    end
    weights[n] = (wavelengths[n] - wavelengths[n - 1]) / 2.0
    return weights
end

"""
    Mount2D(x=0, y=0, yaw=0)

A rigid sensor mount in a body's local frame: `x` points forward, `y` left,
and `yaw` is counter-clockwise relative to the body heading.
"""
struct Mount2D
    position::SVector{2,Float64}
    yaw::Float64

    function Mount2D(position, yaw::Real=0.0)
        p = SVector{2,Float64}(Float64(position[1]), Float64(position[2]))
        yaw_ = Float64(yaw)
        all(isfinite, p) && isfinite(yaw_) ||
            throw(ArgumentError("mount position and yaw must be finite"))
        return new(p, yaw_)
    end
end

Mount2D(x::Real=0.0, y::Real=0.0, yaw::Real=0.0) = Mount2D((x, y), yaw)

function mounted_pose(position, heading::Real, mount::Mount2D)
    px, py = Float64(position[1]), Float64(position[2])
    h = Float64(heading)
    all(isfinite, (px, py, h)) || throw(ArgumentError("body pose must be finite"))
    c, s = cos(h), sin(h)
    x = px + c * mount.position[1] - s * mount.position[2]
    y = py + s * mount.position[1] + c * mount.position[2]
    return (position=SVector{2,Float64}(x, y), heading=mod(h + mount.yaw, 2pi))
end

function mounted_pose(position, heading::Real, mount::Mount2D, arena::Union{Torus,WalledArena})
    pose_ = mounted_pose(position, heading, mount)
    placed = first(arena_position(arena, pose_.position[1], pose_.position[2]))
    return (position=SVector{2,Float64}(placed...), heading=pose_.heading)
end

"""A circular ray-casting target with an arbitrary stable identity."""
struct CircleTarget{I}
    id::I
    centre::SVector{2,Float64}
    radius::Float64

    function CircleTarget(id::I, centre, radius::Real) where {I}
        centre_ = SVector{2,Float64}(Float64(centre[1]), Float64(centre[2]))
        radius_ = Float64(radius)
        all(isfinite, centre_) && isfinite(radius_) && radius_ >= 0.0 ||
            throw(ArgumentError("circle centre must be finite and radius non-negative"))
        return new{I}(id, centre_, radius_)
    end
end

"""The nearest ray hit, retaining both stable target identity and vector index."""
struct RayHit{I}
    id::I
    target_index::Int
    distance::Float64
    point::SVector{2,Float64}
end

@inline function _ray_circle_distance(delta::SVector{2,Float64}, direction::SVector{2,Float64}, radius::Float64)
    projection = dot(delta, direction)
    perpendicular2 = dot(delta, delta) - projection * projection
    radius2 = radius * radius
    perpendicular2 > radius2 && return Inf
    half_chord = sqrt(max(0.0, radius2 - perpendicular2))
    far = projection + half_chord
    far < 0.0 && return Inf
    near = projection - half_chord
    return max(0.0, near)
end

function _target_image_deltas(::WalledArena, origin::SVector{2,Float64}, target::CircleTarget, max_range::Float64)
    return (SVector{2,Float64}(target.centre - origin),)
end

function _target_image_deltas(arena::Torus, origin::SVector{2,Float64}, target::CircleTarget, max_range::Float64)
    isfinite(max_range) || throw(ArgumentError("torus ray casts require a finite max_range"))
    base = SVector{2,Float64}(arena_delta(arena, origin, target.centre))
    extent = ceil(Int, (max_range + target.radius) / arena.size) + 1
    return (
        base + SVector{2,Float64}(kx * arena.size, ky * arena.size)
        for ky in -extent:extent for kx in -extent:extent
    )
end

function nearest_circle_hit(
    origin,
    angle::Real,
    targets::AbstractVector{<:CircleTarget},
    arena::Union{Torus,WalledArena};
    max_range::Real=arena_max_distance(arena),
)
    origin_ = SVector{2,Float64}(Float64(origin[1]), Float64(origin[2]))
    angle_ = Float64(angle)
    range_ = Float64(max_range)
    all(isfinite, origin_) && isfinite(angle_) ||
        throw(ArgumentError("ray origin and angle must be finite"))
    isfinite(range_) && range_ >= 0.0 ||
        throw(ArgumentError("ray max_range must be finite and non-negative"))
    direction = SVector{2,Float64}(cos(angle_), sin(angle_))
    best_distance = Inf
    best_index = 0
    @inbounds for (index, target) in pairs(targets)
        for delta in _target_image_deltas(arena, origin_, target, range_)
            distance = _ray_circle_distance(delta, direction, target.radius)
            if distance <= range_ && distance < best_distance
                best_distance = distance
                best_index = index
            end
        end
    end
    best_index == 0 && return nothing
    point = origin_ + best_distance * direction
    if arena isa Torus
        point = SVector{2,Float64}(wrap(arena, point)...)
    end
    target = targets[best_index]
    return RayHit(target.id, best_index, best_distance, point)
end

"""A circular optical target coupling geometry, identity, and reflectance."""
struct SpectralCircleTarget{I}
    circle::CircleTarget{I}
    reflectance::SpectralReflectance
end

SpectralCircleTarget(id, centre, radius::Real, reflectance::SpectralReflectance) =
    SpectralCircleTarget(CircleTarget(id, centre, radius), reflectance)

"""
    SpectralCamera(grid, channels, sensitivity; ray_angles, ...)

An arbitrary-channel camera. Sensitivity rows are channels and columns are the
camera grid's wavelengths. Camera samples are flattened channel-major.
"""
struct SpectralCamera <: AbstractSensor
    grid::SpectralGrid
    channels::Vector{Symbol}
    sensitivity::Matrix{Float64}
    ray_angles::Vector{Float64}
    mount::Mount2D
    max_range::Float64
    exposure::Float64
    saturation::Float64
    weights::Vector{Float64}
end

function SpectralCamera(
    grid::SpectralGrid,
    channels,
    sensitivity;
    ray_angles=(0.0,),
    mount=Mount2D(),
    max_range::Real=Inf,
    exposure::Real=1.0,
    saturation::Real=Inf,
)
    channel_names = Symbol.(vec(collect(channels)))
    isempty(channel_names) && throw(ArgumentError("a spectral camera needs at least one channel"))
    length(unique(channel_names)) == length(channel_names) ||
        throw(ArgumentError("spectral-camera channel names must be unique"))
    matrix = Matrix{Float64}(sensitivity)
    size(matrix) == (length(channel_names), length(grid)) || throw(DimensionMismatch(
        "camera sensitivity has size $(size(matrix)); expected ($(length(channel_names)), $(length(grid)))",
    ))
    all(isfinite, matrix) && all(>=(0.0), matrix) ||
        throw(ArgumentError("camera sensitivities must be finite and non-negative"))
    all(row -> any(>(0.0), @view(matrix[row, :])), axes(matrix, 1)) ||
        throw(ArgumentError("every camera channel needs a non-zero sensitivity"))
    angles = Float64.(vec(collect(ray_angles)))
    !isempty(angles) && all(isfinite, angles) ||
        throw(ArgumentError("camera ray angles must be a non-empty finite vector"))
    mount isa Mount2D || throw(ArgumentError("camera mount must be a Mount2D"))
    range_ = Float64(max_range)
    exposure_ = Float64(exposure)
    saturation_ = Float64(saturation)
    (isfinite(range_) || range_ == Inf) && range_ > 0.0 ||
        throw(ArgumentError("camera max_range must be positive"))
    isfinite(exposure_) && exposure_ >= 0.0 ||
        throw(ArgumentError("camera exposure must be finite and non-negative"))
    (isfinite(saturation_) || saturation_ == Inf) && saturation_ > 0.0 ||
        throw(ArgumentError("camera saturation must be positive"))
    return SpectralCamera(
        grid, channel_names, matrix, angles, mount, range_, exposure_, saturation_,
        _trapezoid_weights(grid),
    )
end

n_camera_channels(camera::SpectralCamera) = length(camera.channels)
n_camera_rays(camera::SpectralCamera) = length(camera.ray_angles)
n_sensors(camera::SpectralCamera) = n_camera_channels(camera) * n_camera_rays(camera)
rawspec(camera::SpectralCamera) = (
    kind=:spectral_camera,
    width=n_sensors(camera),
    channels=Tuple(camera.channels),
    rays=Tuple(camera.ray_angles),
    layout=:channel_major,
)

function relative_radiometric_response(
    camera::SpectralCamera,
    reflectance::SpectralReflectance,
    illuminant::SpectralIlluminant,
)
    _require_grid_match(camera.grid, reflectance.grid, "reflectance")
    _require_grid_match(camera.grid, illuminant.grid, "illuminant")
    output = Vector{Float64}(undef, n_camera_channels(camera))
    @inbounds for channel in eachindex(output)
        value = 0.0
        for wavelength in eachindex(camera.weights)
            value += camera.weights[wavelength] *
                     illuminant.values[wavelength] *
                     reflectance.values[wavelength] *
                     camera.sensitivity[channel, wavelength]
        end
        output[channel] = min(camera.saturation, camera.exposure * value)
    end
    return output
end

function sample_spectral_camera(
    camera::SpectralCamera,
    position,
    heading::Real,
    targets::AbstractVector{T},
    illuminant::SpectralIlluminant,
    arena::Union{Torus,WalledArena},
) where {I,T<:SpectralCircleTarget{I}}
    _require_grid_match(camera.grid, illuminant.grid, "illuminant")
    camera_pose = mounted_pose(position, heading, camera.mount, arena)
    circles = CircleTarget{I}[target.circle for target in targets]
    rays = n_camera_rays(camera)
    channels = n_camera_channels(camera)
    output = zeros(Float64, channels * rays)
    hits = Vector{Union{Nothing,RayHit{I}}}(undef, rays)
    range_ = isfinite(camera.max_range) ? camera.max_range : arena_max_distance(arena)
    @inbounds for ray in 1:rays
        hit = nearest_circle_hit(
            camera_pose.position,
            camera_pose.heading + camera.ray_angles[ray],
            circles,
            arena;
            max_range=range_,
        )
        hits[ray] = hit
        hit === nothing && continue
        response = relative_radiometric_response(
            camera,
            targets[hit.target_index].reflectance,
            illuminant,
        )
        for channel in 1:channels
            output[(channel - 1) * rays + ray] = response[channel]
        end
    end
    return (values=output, hits=hits)
end

# Smooth analytic approximations to the CIE 1931 2-degree colour-matching curves.
@inline _asym_gaussian(w, centre, left, right) =
    exp(-0.5 * ((w - centre) * (w < centre ? left : right))^2)
@inline _cie_x(w) = 0.362 * _asym_gaussian(w, 442.0, 0.0624, 0.0374) +
                    1.056 * _asym_gaussian(w, 599.8, 0.0264, 0.0323) -
                    0.065 * _asym_gaussian(w, 501.1, 0.0490, 0.0382)
@inline _cie_y(w) = 0.821 * _asym_gaussian(w, 568.8, 0.0213, 0.0247) +
                    0.286 * _asym_gaussian(w, 530.9, 0.0613, 0.0322)
@inline _cie_z(w) = 1.217 * _asym_gaussian(w, 437.0, 0.0845, 0.0278) +
                    0.681 * _asym_gaussian(w, 459.0, 0.0385, 0.0725)

@inline function _srgb_encode(value::Float64)
    value_ = clamp(value, 0.0, 1.0)
    return value_ <= 0.0031308 ? 12.92 * value_ : 1.055 * value_^(1 / 2.4) - 0.055
end

"""Convert reflected relative radiance to a display sRGB triple in `[0, 1]`."""
function display_rgb(reflectance::SpectralReflectance, illuminant::SpectralIlluminant)
    _require_grid_match(reflectance.grid, illuminant.grid, "illuminant")
    grid = reflectance.grid
    weights = _trapezoid_weights(grid)
    X = Y = Z = white_Y = 0.0
    @inbounds for i in eachindex(weights)
        wavelength = grid.wavelengths_nm[i]
        xbar, ybar, zbar = _cie_x(wavelength), _cie_y(wavelength), _cie_z(wavelength)
        incident = weights[i] * illuminant.values[i]
        reflected = incident * reflectance.values[i]
        X += reflected * xbar
        Y += reflected * ybar
        Z += reflected * zbar
        white_Y += incident * ybar
    end
    white_Y <= eps(Float64) && return (0.0, 0.0, 0.0)
    X /= white_Y
    Y /= white_Y
    Z /= white_Y
    r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z
    g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
    b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z
    peak = max(r, g, b)
    if peak > 1.0
        r /= peak
        g /= peak
        b /= peak
    end
    return (_srgb_encode(r), _srgb_encode(g), _srgb_encode(b))
end
