using Random

struct Wiring <: Connectome
    N::Int
    K_rec::Int
    K_in::Int
    K::Int
    dend_source::Matrix{Int}
    node_sources::Matrix{Int}
    receptor_sources::Matrix{Int}
    mode::Symbol
    fwd_unit::Union{Nothing,Matrix{Int}}
    back_src::Union{Nothing,Matrix{Int}}
    R_fwd::Union{Nothing,Array{Float64,3}}
    fwd_count::Union{Nothing,Matrix{Float64}}
    M_ne::BitMatrix
    effector_sources::Vector{Vector{Int}}
    n_receptors::Int
    n_effectors::Int
end

const CompartmentalConnectome = Wiring

function _wiring_mode(mode::Symbol)
    mode in (:dense, :structured) ||
        throw(ArgumentError("unknown compartmental wiring mode :$mode"))
    return mode
end

_wiring_mode(mode::AbstractString) = _wiring_mode(Symbol(mode))

function _wiring_int_matrix(x, name::AbstractString)
    ndims(x) == 2 || throw(ArgumentError("$name must be a matrix"))
    return Matrix{Int}(Int.(x))
end

function _wiring_maybe_int_matrix(x, name::AbstractString)
    if x === nothing || (x isa AbstractArray && length(x) == 0)
        return nothing
    end
    return _wiring_int_matrix(x, name)
end

function _wiring_float_matrix(x, name::AbstractString)
    ndims(x) == 2 || throw(ArgumentError("$name must be a matrix"))
    return Matrix{Float64}(Float64.(x))
end

function _wiring_maybe_float_matrix(x, name::AbstractString)
    if x === nothing || (x isa AbstractArray && length(x) == 0)
        return nothing
    end
    return _wiring_float_matrix(x, name)
end

function _wiring_maybe_float_array3(x, name::AbstractString)
    if x === nothing || (x isa AbstractArray && length(x) == 0)
        return nothing
    end
    ndims(x) == 3 || throw(ArgumentError("$name must be a rank-3 array"))
    return Array{Float64,3}(Float64.(x))
end

function _wiring_bitmatrix(x, name::AbstractString)
    ndims(x) == 2 || throw(ArgumentError("$name must be a matrix"))
    mask = falses(size(x, 1), size(x, 2))
    @inbounds for j in axes(mask, 2), i in axes(mask, 1)
        mask[i, j] = x[i, j] != 0
    end
    return mask
end

function _wiring_effector_sources(M_ne::BitMatrix)
    sources = Vector{Vector{Int}}(undef, size(M_ne, 2))
    @inbounds for k in axes(M_ne, 2)
        sources[k] = findall(@view M_ne[:, k])
    end
    return sources
end

function _compute_R_fwd(fwd_unit::Matrix{Int}, N::Int, K::Int)
    R_fwd = zeros(Float64, N, K, COMPARTMENTAL_S)
    @inbounds for n in 1:N, k in 1:K
        unit = fwd_unit[n, k] + 1
        1 <= unit <= COMPARTMENTAL_S ||
            throw(ArgumentError("fwd_unit contains out-of-range soma unit $(unit - 1)"))
        R_fwd[n, k, unit] = 1.0
    end
    return R_fwd
end

function _compute_fwd_count(R_fwd::Array{Float64,3})
    N = size(R_fwd, 1)
    S = size(R_fwd, 3)
    counts = zeros(Float64, N, S)
    @inbounds for n in 1:N, s in 1:S
        total = 0.0
        for k in axes(R_fwd, 2)
            total += R_fwd[n, k, s]
        end
        counts[n, s] = total
    end
    return counts
end

function _validate_wiring_dimensions(w::Wiring)
    size(w.dend_source) == (w.N, w.K) ||
        throw(DimensionMismatch("dend_source size $(size(w.dend_source)) must be ($(w.N), $(w.K))"))
    size(w.node_sources) == (w.N, w.K_rec) ||
        throw(DimensionMismatch("node_sources size $(size(w.node_sources)) must be ($(w.N), $(w.K_rec))"))
    size(w.receptor_sources) == (w.N, w.K_in) ||
        throw(DimensionMismatch("receptor_sources size $(size(w.receptor_sources)) must be ($(w.N), $(w.K_in))"))
    size(w.M_ne) == (w.N, w.n_effectors) ||
        throw(DimensionMismatch("M_ne size $(size(w.M_ne)) must be ($(w.N), $(w.n_effectors))"))

    @inbounds for n in 1:w.N, k in 1:w.K
        src = w.dend_source[n, k]
        0 <= src < w.N + w.n_receptors ||
            throw(ArgumentError("dend_source[$n,$k] = $src is outside [0, $(w.N + w.n_receptors - 1)]"))
    end

    @inbounds for n in 1:w.N, k in 1:w.K_rec
        src = w.node_sources[n, k]
        0 <= src < w.N ||
            throw(ArgumentError("node_sources[$n,$k] = $src is outside [0, $(w.N - 1)]"))
    end

    @inbounds for n in 1:w.N, k in 1:w.K_in
        src = w.receptor_sources[n, k]
        0 <= src < w.n_receptors ||
            throw(ArgumentError("receptor_sources[$n,$k] = $src is outside [0, $(w.n_receptors - 1)]"))
    end

    if w.mode == :structured
        w.fwd_unit !== nothing || throw(ArgumentError("structured wiring requires fwd_unit"))
        w.back_src !== nothing || throw(ArgumentError("structured wiring requires back_src"))
        w.R_fwd !== nothing || throw(ArgumentError("structured wiring requires R_fwd"))
        w.fwd_count !== nothing || throw(ArgumentError("structured wiring requires fwd_count"))
        size(w.fwd_unit) == (w.N, w.K) ||
            throw(DimensionMismatch("fwd_unit size $(size(w.fwd_unit)) must be ($(w.N), $(w.K))"))
        size(w.back_src) == (w.N, w.K) ||
            throw(DimensionMismatch("back_src size $(size(w.back_src)) must be ($(w.N), $(w.K))"))
        size(w.R_fwd) == (w.N, w.K, COMPARTMENTAL_S) ||
            throw(DimensionMismatch("R_fwd size $(size(w.R_fwd)) must be ($(w.N), $(w.K), $(COMPARTMENTAL_S))"))
        size(w.fwd_count) == (w.N, COMPARTMENTAL_S) ||
            throw(DimensionMismatch("fwd_count size $(size(w.fwd_count)) must be ($(w.N), $(COMPARTMENTAL_S))"))

        @inbounds for n in 1:w.N, k in 1:w.K
            fwd = w.fwd_unit[n, k]
            back = w.back_src[n, k]
            0 <= fwd < COMPARTMENTAL_S ||
                throw(ArgumentError("fwd_unit[$n,$k] = $fwd is outside [0, $(COMPARTMENTAL_S - 1)]"))
            0 <= back < COMPARTMENTAL_S ||
                throw(ArgumentError("back_src[$n,$k] = $back is outside [0, $(COMPARTMENTAL_S - 1)]"))
            fwd != back ||
                throw(ArgumentError("structured wiring requires fwd_unit[$n,$k] != back_src[$n,$k]"))
        end
    end

    return w
end

function _wiring_rng(seed)
    return seed === nothing ? Random.Xoshiro() : Random.Xoshiro(Int(seed))
end

function _sample_0based_without_replacement!(dest, rng::AbstractRNG, population::Vector{Int})
    length(dest) <= length(population) ||
        throw(ArgumentError("cannot sample $(length(dest)) values without replacement from $(length(population)) candidates"))

    order = randperm(rng, length(population))
    @inbounds for k in eachindex(dest)
        dest[k] = population[order[k]]
    end
    return dest
end

function _sample_receptors!(dest, rng::AbstractRNG, n_receptors::Int)
    if length(dest) > n_receptors
        @inbounds for k in eachindex(dest)
            dest[k] = rand(rng, 0:(n_receptors - 1))
        end
    else
        population = collect(0:(n_receptors - 1))
        _sample_0based_without_replacement!(dest, rng, population)
    end
    return dest
end

function _fill_structured_routes!(rng::AbstractRNG, fwd_unit::Matrix{Int}, back_src::Matrix{Int}, K_rec::Int, K_in::Int)
    N = size(fwd_unit, 1)
    K = size(fwd_unit, 2)

    @inbounds for n in 1:N, k in 1:K
        fwd_unit[n, k] = rand(rng, 0:(COMPARTMENTAL_S - 1))
        back_src[n, k] = rand(rng, 0:(COMPARTMENTAL_S - 1))
    end

    if K_in >= 1
        cover_len = min(COMPARTMENTAL_S, K_in)
        @inbounds for n in 1:N
            order = randperm(rng, COMPARTMENTAL_S)
            for j in 1:cover_len
                fwd_unit[n, K_rec + j] = order[j] - 1
            end
        end
    end

    changed = true
    while changed
        changed = false
        @inbounds for n in 1:N, k in 1:K
            if back_src[n, k] == fwd_unit[n, k]
                back_src[n, k] = rand(rng, 0:(COMPARTMENTAL_S - 1))
                changed = true
            end
        end
    end

    return fwd_unit, back_src
end

function build_wiring(
    N::Integer,
    seed;
    link_p::Real=0.1,
    n_receptors::Integer,
    n_effectors::Integer,
    rho::Real=0.2,
    mode=:structured,
)
    N_ = Int(N)
    n_receptors_ = Int(n_receptors)
    n_effectors_ = Int(n_effectors)
    mode_ = _wiring_mode(mode)
    link_p_ = Float64(link_p)
    rho_ = Float64(rho)

    N_ >= 1 || throw(ArgumentError("N must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))
    0.0 <= link_p_ <= 1.0 || throw(ArgumentError("link_p must be in [0, 1]"))
    rho_ >= 0.0 || throw(ArgumentError("rho must be non-negative"))

    rng = _wiring_rng(seed)
    K_rec_ = min(N_ - 1, max(1, round(Int, link_p_ * (N_ - 1))))
    K_in_ = max(1, round(Int, rho_ * K_rec_))
    K_ = K_rec_ + K_in_

    node_sources = Matrix{Int}(undef, N_, K_rec_)
    receptor_sources = Matrix{Int}(undef, N_, K_in_)
    dend_source = Matrix{Int}(undef, N_, K_)

    @inbounds for n in 1:N_
        if K_rec_ > 0
            others = Vector{Int}(undef, N_ - 1)
            idx = 1
            for src in 0:(N_ - 1)
                if src != n - 1
                    others[idx] = src
                    idx += 1
                end
            end
            _sample_0based_without_replacement!(@view(node_sources[n, :]), rng, others)
        end

        _sample_receptors!(@view(receptor_sources[n, :]), rng, n_receptors_)

        for k in 1:K_rec_
            dend_source[n, k] = node_sources[n, k]
        end
        for k in 1:K_in_
            dend_source[n, K_rec_ + k] = N_ + receptor_sources[n, k]
        end
    end

    M_ne = falses(N_, n_effectors_)
    @inbounds for eff in 1:n_effectors_
        any_source = false
        for n in 1:N_
            connected = rand(rng) < link_p_
            M_ne[n, eff] = connected
            any_source |= connected
        end
        if !any_source
            M_ne[rand(rng, 1:N_), eff] = true
        end
    end

    fwd_unit = nothing
    back_src = nothing
    R_fwd = nothing
    fwd_count = nothing
    if mode_ == :structured
        fwd_unit = Matrix{Int}(undef, N_, K_)
        back_src = Matrix{Int}(undef, N_, K_)
        _fill_structured_routes!(rng, fwd_unit, back_src, K_rec_, K_in_)
        R_fwd = _compute_R_fwd(fwd_unit, N_, K_)
        fwd_count = _compute_fwd_count(R_fwd)
    end

    return inject_wiring(
        mode=mode_,
        dend_source=dend_source,
        M_ne=M_ne,
        node_sources=node_sources,
        receptor_sources=receptor_sources,
        fwd_unit=fwd_unit,
        back_src=back_src,
        R_fwd=R_fwd,
        fwd_count=fwd_count,
        N=N_,
        K_rec=K_rec_,
        K_in=K_in_,
        K=K_,
        n_receptors=n_receptors_,
        n_effectors=n_effectors_,
    )
end

function inject_wiring(;
    mode,
    dend_source,
    M_ne,
    node_sources=nothing,
    receptor_sources=nothing,
    fwd_unit=nothing,
    back_src=nothing,
    R_fwd=nothing,
    fwd_count=nothing,
    N=nothing,
    K_rec=nothing,
    K_in=nothing,
    K=nothing,
    n_receptors=nothing,
    n_effectors=nothing,
)
    mode_ = _wiring_mode(mode)
    dend_source_ = _wiring_int_matrix(dend_source, "dend_source")
    N_ = N === nothing ? size(dend_source_, 1) : Int(N)
    K_ = K === nothing ? size(dend_source_, 2) : Int(K)

    node_sources_ =
        node_sources === nothing ?
        Matrix{Int}(dend_source_[:, 1:(K_rec === nothing ? 0 : Int(K_rec))]) :
        _wiring_int_matrix(node_sources, "node_sources")
    K_rec_ = K_rec === nothing ? size(node_sources_, 2) : Int(K_rec)

    receptor_sources_ =
        receptor_sources === nothing ?
        Matrix{Int}(dend_source_[:, (K_rec_ + 1):K_] .- N_) :
        _wiring_int_matrix(receptor_sources, "receptor_sources")
    K_in_ = K_in === nothing ? size(receptor_sources_, 2) : Int(K_in)

    if node_sources === nothing
        node_sources_ = Matrix{Int}(dend_source_[:, 1:K_rec_])
    end
    if receptor_sources === nothing
        receptor_sources_ = Matrix{Int}(dend_source_[:, (K_rec_ + 1):K_] .- N_)
    end

    n_receptors_ =
        n_receptors === nothing ?
        (isempty(receptor_sources_) ? 0 : maximum(receptor_sources_) + 1) :
        Int(n_receptors)
    M_ne_ = _wiring_bitmatrix(M_ne, "M_ne")
    n_effectors_ = n_effectors === nothing ? size(M_ne_, 2) : Int(n_effectors)

    fwd_unit_ = _wiring_maybe_int_matrix(fwd_unit, "fwd_unit")
    back_src_ = _wiring_maybe_int_matrix(back_src, "back_src")
    R_fwd_ = _wiring_maybe_float_array3(R_fwd, "R_fwd")
    fwd_count_ = _wiring_maybe_float_matrix(fwd_count, "fwd_count")

    if mode_ == :structured
        fwd_unit_ !== nothing || throw(ArgumentError("structured wiring requires fwd_unit"))
        back_src_ !== nothing || throw(ArgumentError("structured wiring requires back_src"))
        R_fwd_ = R_fwd_ === nothing ? _compute_R_fwd(fwd_unit_, N_, K_) : R_fwd_
        fwd_count_ = fwd_count_ === nothing ? _compute_fwd_count(R_fwd_) : fwd_count_
    else
        fwd_unit_ = nothing
        back_src_ = nothing
        R_fwd_ = nothing
        fwd_count_ = nothing
    end

    w = Wiring(
        N_,
        K_rec_,
        K_in_,
        K_,
        dend_source_,
        node_sources_,
        receptor_sources_,
        mode_,
        fwd_unit_,
        back_src_,
        R_fwd_,
        fwd_count_,
        M_ne_,
        _wiring_effector_sources(M_ne_),
        n_receptors_,
        n_effectors_,
    )

    return _validate_wiring_dimensions(w)
end

n_receptors(w::Wiring) = w.n_receptors
n_effectors(w::Wiring) = w.n_effectors
