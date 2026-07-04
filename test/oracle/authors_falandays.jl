#!/usr/bin/env julia

using JLD2
using LinearAlgebra
using Random
using Statistics

Base.@kwdef struct AuthorTask
    name::Symbol
    nnodes::Int
    n_receptors::Int
    n_effectors::Int = 2
    p_link::Float64 = 0.1
    leak::Float64 = 0.25
    lrate_wmat::Float64
    lrate_targ::Float64
    targ_min::Float64 = 1.0
    input_amp::Float64
    weight_init_mode::Symbol
    ticks::Int = 48
end

const AUTHOR_TASKS = Dict{Symbol,AuthorTask}(
    :wall => AuthorTask(
        name=:wall,
        nnodes=200,
        n_receptors=2,
        lrate_wmat=1.0,
        lrate_targ=0.01,
        input_amp=4.0,
        weight_init_mode=:excitatory,
    ),
    :tracking => AuthorTask(
        name=:tracking,
        nnodes=200,
        n_receptors=62,
        lrate_wmat=1.0,
        lrate_targ=0.01,
        input_amp=0.75,
        weight_init_mode=:excitatory,
    ),
    :pong => AuthorTask(
        name=:pong,
        nnodes=500,
        n_receptors=46,
        lrate_wmat=1.0,
        lrate_targ=0.1,
        input_amp=2.75,
        weight_init_mode=:pong_mixed,
    ),
)

const AUTHOR_FIXTURE_SEED = 20260704
const AUTHOR_TASK_SEED_OFFSETS = Dict(:wall => 11, :tracking => 23, :pong => 37)

function _recorded_inputs(task::AuthorTask, rng::AbstractRNG)
    inputs = rand(rng, task.ticks, task.n_receptors)
    if task.name === :wall
        @inbounds for t in axes(inputs, 1)
            inputs[t, 1] = 0.25 + 0.75 * inputs[t, 1]
            inputs[t, 2] = 0.15 + 0.85 * inputs[t, 2]
        end
    elseif task.name === :pong
        fill!(inputs, 0.0)
        @inbounds for t in axes(inputs, 1)
            idx = mod1(t, task.n_receptors)
            inputs[t, idx] = 1.0
            inputs[t, mod1(idx + 1, task.n_receptors)] = 1.0
        end
    end
    return inputs
end

function _build_author_network(task::AuthorTask, rng::AbstractRNG)
    n = task.nnodes
    input_wmat = zeros(Float64, task.n_receptors, n)
    @inbounds for row in axes(input_wmat, 1), col in axes(input_wmat, 2)
        input_wmat[row, col] = rand(rng) < task.p_link ? task.input_amp : 0.0
    end

    link_mat = zeros(Float64, n, n)
    @inbounds for row in axes(link_mat, 1)
        rand(rng) < 0.25 # overwritten in the authors' single-agent scripts
        inhibitory = false
        for col in axes(link_mat, 2)
            if row == col
                continue
            elseif inhibitory
                link_mat[row, col] = rand(rng) < task.p_link ? -1.0 : 0.0
            else
                link_mat[row, col] = rand(rng) < task.p_link ? 1.0 : 0.0
            end
        end
    end

    wmat0 = zeros(Float64, n, n)
    @inbounds for row in axes(wmat0, 1), col in axes(wmat0, 2)
        if link_mat[row, col] == 1.0
            if task.weight_init_mode === :excitatory
                wmat0[row, col] = task.input_amp + 0.1 * randn(rng)
            elseif task.weight_init_mode === :pong_mixed
                inhibitory = rand(rng) < 0.25
                wmat0[row, col] = inhibitory ? -1.0 + 0.1 * randn(rng) : 0.2 * randn(rng)
            else
                throw(ArgumentError("unknown author init mode $(task.weight_init_mode)"))
            end
        elseif link_mat[row, col] == -1.0
            wmat0[row, col] = -task.input_amp + 0.1 * randn(rng)
        end
    end

    output_mask = zeros(Float64, n, task.n_effectors)
    @inbounds for row in axes(output_mask, 1), col in axes(output_mask, 2)
        output_mask[row, col] = rand(rng) < task.p_link ? 1.0 : 0.0
    end

    return (
        recurrent_mask=link_mat .!= 0.0,
        link_mat=link_mat,
        input_wmat=input_wmat,
        output_mask=output_mask,
        wmat0=wmat0,
    )
end

mutable struct AuthorState
    acts::Vector{Float64}
    targets::Vector{Float64}
    spikes::Vector{Float64}
    wmat::Matrix{Float64}
end

function AuthorState(task::AuthorTask, wmat0::AbstractMatrix{<:Real})
    return AuthorState(
        zeros(Float64, task.nnodes),
        fill(task.targ_min, task.nnodes),
        zeros(Float64, task.nnodes),
        Matrix{Float64}(wmat0),
    )
end

function _author_learning!(
    state::AuthorState,
    task::AuthorTask,
    link_mat::AbstractMatrix{<:Real},
    prev_spikes::AbstractVector{<:Real},
    errors::AbstractVector{<:Real},
)
    active_neighbors = abs.(link_mat)
    @inbounds for row in axes(active_neighbors, 1)
        if prev_spikes[row] == 0.0
            active_neighbors[row, :] .= 0.0
        end
    end
    counts = vec(sum(active_neighbors; dims=1))

    if sum(counts) > 0.0
        @inbounds for col in axes(state.wmat, 2)
            count = counts[col]
            if count > 0.0
                delta = errors[col] / count * task.lrate_wmat
                for row in axes(state.wmat, 1)
                    if active_neighbors[row, col] != 0.0
                        state.wmat[row, col] -= delta
                    end
                end
            end
        end
    end

    @inbounds for i in eachindex(state.targets)
        state.targets[i] += errors[i] * task.lrate_targ
        if state.targets[i] < task.targ_min
            state.targets[i] = task.targ_min
        end
    end
    return state
end

function _author_step!(
    state::AuthorState,
    task::AuthorTask,
    network,
    input::AbstractVector{<:Real},
)
    prev_spikes = copy(state.spikes)
    input_current = vec(transpose(input) * network.input_wmat)
    recurrent_current = vec(transpose(prev_spikes) * state.wmat)
    state.acts .= state.acts .* (1.0 - task.leak) .+ input_current .+ recurrent_current

    thresholds = state.targets .* 2.0
    @inbounds for i in eachindex(state.spikes)
        state.spikes[i] = state.acts[i] >= thresholds[i] ? 1.0 : 0.0
        if state.spikes[i] == 1.0
            state.acts[i] -= thresholds[i]
        end
    end
    errors = state.acts .- state.targets
    _author_learning!(state, task, network.link_mat, prev_spikes, errors)
    return copy(errors)
end

function build_fixture(task::AuthorTask; seed::Integer=AUTHOR_FIXTURE_SEED)
    rng = MersenneTwister(Int(seed) + AUTHOR_TASK_SEED_OFFSETS[task.name])
    network = _build_author_network(task, rng)
    inputs = _recorded_inputs(task, rng)
    state = AuthorState(task, network.wmat0)

    acts_T = zeros(Float64, task.ticks, task.nnodes)
    targets_T = zeros(Float64, task.ticks, task.nnodes)
    spikes_T = zeros(Float64, task.ticks, task.nnodes)
    errors_T = zeros(Float64, task.ticks, task.nnodes)
    wmat_final = similar(network.wmat0)

    @inbounds for t in 1:task.ticks
        errors = _author_step!(state, task, network, vec(inputs[t, :]))
        acts_T[t, :] .= state.acts
        targets_T[t, :] .= state.targets
        spikes_T[t, :] .= state.spikes
        errors_T[t, :] .= errors
    end
    wmat_final .= state.wmat

    return (
        task=task.name,
        seed=Int(seed),
        ticks=task.ticks,
        nnodes=task.nnodes,
        n_receptors=task.n_receptors,
        n_effectors=task.n_effectors,
        p_link=task.p_link,
        leak=task.leak,
        lrate_wmat=task.lrate_wmat,
        lrate_targ=task.lrate_targ,
        targ_min=task.targ_min,
        input_amp=task.input_amp,
        weight_init_mode=task.weight_init_mode,
        inputs=inputs,
        recurrent_mask=network.recurrent_mask,
        input_wmat=network.input_wmat,
        output_mask=network.output_mask,
        wmat0=network.wmat0,
        wmat_final=wmat_final,
        acts_T=acts_T,
        targets_T=targets_T,
        spikes_T=spikes_T,
        errors_T=errors_T,
    )
end

function write_fixture(task::AuthorTask, out_dir::AbstractString; seed::Integer=AUTHOR_FIXTURE_SEED)
    mkpath(out_dir)
    data = build_fixture(task; seed=seed)
    out_path = joinpath(out_dir, "authors_$(task.name).jld2")
    jldsave(out_path; data...)
    println(
        "wrote $(out_path) task=$(task.name) N=$(task.nnodes) ticks=$(task.ticks) " *
        "total_spikes=$(Int(sum(data.spikes_T))) final_mean_target=$(mean(data.targets_T[end, :]))",
    )
    return out_path
end

function main(args=ARGS)
    out_dir = joinpath(dirname(@__DIR__), "fixtures")
    selected =
        isempty(args) ? sort!(collect(keys(AUTHOR_TASKS))) :
        Symbol.(args)
    for task_name in selected
        haskey(AUTHOR_TASKS, task_name) ||
            throw(ArgumentError("unknown task :$(task_name); expected one of $(sort!(collect(keys(AUTHOR_TASKS))))"))
        write_fixture(AUTHOR_TASKS[task_name], out_dir)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
