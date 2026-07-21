using .ExpHarness, .ExpRegistry
using BrainlessLab
using Dates
using JLD2
using SHA
using Statistics
using TOML

const SHOAL_PROTOCOL_PATH = joinpath(@__DIR__, "shoal_vision_sweep", "protocol.toml")
const SHOAL_RANGES = (2.0, 3.5, 5.0, 7.0, 10.0)
const SHOAL_DIAGNOSTIC_LOCK = ReentrantLock()

_shoal_bool(value) = value === true || value === :true ||
    (value isa AbstractString && lowercase(value) == "true")

function _shoal_profile(profile)
    profile_ = Symbol(profile)
    profile_ in (:pilot, :full) || throw(ArgumentError("profile must be :pilot or :full"))
    return profile_
end

function _shoal_seed(block::Integer)
    return 73_000 + 1_009 * Int(block)
end

function _shoal_conditions(blocks)
    jobs = NamedTuple[]
    for block in blocks, association_need in (false, true)
        push!(jobs, (
            block=Int(block),
            association_need,
            mode=:blind,
            conspecific_range=5.0,
        ))
        for mode in (:veridical, :bearing_sham), range in SHOAL_RANGES
            push!(jobs, (
                block=Int(block),
                association_need,
                mode,
                conspecific_range=range,
            ))
        end
    end
    return jobs
end

function _shoal_job_id(job)
    association = job.association_need ? "association_on" : "association_off"
    range = replace(string(job.conspecific_range), "." => "p")
    return "block_$(job.block)__$(association)__$(job.mode)__range_$(range)"
end

function _shoal_atomic(writer, path::AbstractString)
    mkpath(dirname(path))
    temporary = path * ".tmp.$(getpid()).$(Threads.threadid())"
    writer(temporary)
    mv(temporary, path; force=true)
    return path
end

function _shoal_write_toml(path, value)
    return _shoal_atomic(path) do temporary
        open(temporary, "w") do io
            TOML.print(io, value)
        end
    end
end

function _shoal_csv_cell(value)
    value === nothing && return ""
    value isa EntityID && return string(value.value)
    text = value isa AbstractFloat ? repr(Float64(value)) : string(value)
    if occursin(',', text) || occursin('"', text) || occursin('\n', text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function _shoal_write_csv(path, rows)
    rows_ = collect(rows)
    isempty(rows_) && return _shoal_atomic(path) do temporary
        open(temporary, "w") do io end
    end
    columns = propertynames(first(rows_))
    return _shoal_atomic(path) do temporary
        open(temporary, "w") do io
            println(io, join(string.(columns), ','))
            for row in rows_
                println(io, join((_shoal_csv_cell(getproperty(row, column)) for column in columns), ','))
            end
        end
    end
end

function _shoal_json_escape(value)
    return replace(String(value), '\\' => "\\\\", '"' => "\\\"", '\n' => "\\n")
end

function _shoal_json(io, value)
    if value === nothing || value === missing
        print(io, "null")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa Integer
        print(io, value)
    elseif value isa AbstractFloat
        isfinite(value) ? print(io, repr(Float64(value))) : print(io, "null")
    elseif value isa EntityID
        print(io, value.value)
    elseif value isa Symbol || value isa AbstractString
        print(io, '"', _shoal_json_escape(string(value)), '"')
    elseif value isa NamedTuple
        _shoal_json(io, Dict(string(key) => getproperty(value, key) for key in propertynames(value)))
    elseif value isa AbstractDict
        print(io, '{')
        for (index, key) in enumerate(sort!(collect(keys(value)); by=string))
            index > 1 && print(io, ',')
            print(io, '"', _shoal_json_escape(string(key)), "\":")
            _shoal_json(io, value[key])
        end
        print(io, '}')
    elseif value isa Tuple || value isa AbstractVector
        print(io, '[')
        for (index, item) in enumerate(value)
            index > 1 && print(io, ',')
            _shoal_json(io, item)
        end
        print(io, ']')
    else
        print(io, '"', _shoal_json_escape(string(value)), '"')
    end
end

function _shoal_write_json(path, value)
    return _shoal_atomic(path) do temporary
        open(temporary, "w") do io
            _shoal_json(io, value)
            println(io)
        end
    end
end

_shoal_hash(path) = isfile(path) ? bytes2hex(sha256(read(path))) : "missing"

function _shoal_git(command)
    try
        return readchomp(command)
    catch
        return "unknown"
    end
end

function _shoal_manifest(profile, blocks, ticks, warmup, jobs)
    root = pkgdir(BrainlessLab)
    project = Base.active_project()
    manifest = joinpath(dirname(project), "Manifest.toml")
    return Dict{String,Any}(
        "schema" => "brainlesslab-shoal-sweep-v1",
        "status" => "initializing",
        "evidence_status" => "exploratory",
        "profile" => string(profile),
        "blocks" => collect(Int.(blocks)),
        "ticks" => Int(ticks),
        "warmup" => Int(warmup),
        "jobs" => length(jobs),
        "git_sha" => _shoal_git(`git -C $root rev-parse HEAD`),
        "git_dirty" => !isempty(_shoal_git(`git -C $root status --porcelain`)),
        "julia_version" => string(VERSION),
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "threads" => Threads.nthreads(),
        "project" => project,
        "project_sha256" => _shoal_hash(project),
        "manifest_sha256" => _shoal_hash(manifest),
        "protocol_sha256" => _shoal_hash(SHOAL_PROTOCOL_PATH),
        "created_utc" => string(Dates.now(Dates.UTC)),
        "seed_ledger" => Dict(string(block) => _shoal_seed(block) for block in blocks),
    )
end

function _shoal_status!(dir, status; details=Dict{String,Any}())
    value = Dict{String,Any}(
        "status" => string(status),
        "updated_utc" => string(Dates.now(Dates.UTC)),
    )
    merge!(value, details)
    _shoal_write_toml(joinpath(dir, "status.toml"), value)
end

function _shoal_vertical_slice!()
    sim = simulate(
        :shoal_forage;
        node=:falandays,
        ticks=5,
        seed=71,
        n_nodes=40,
        n_agents=4,
        substeps=2,
        every=1,
        task_kwargs=(
            block=1,
            association_need=true,
            conspecific_mode=:veridical,
            conspecific_range=5.0,
        ),
        record=(:needs, :poses, :interactions, :rate),
    )
    length(getchannel(sim.recorder, :needs)) == 5 || error("vertical slice did not record needs")
    all(isfinite, first(getchannel(sim.recorder, :rate))) || error("vertical slice produced non-finite rate")
    return nothing
end

function _shoal_benchmark(block, ticks, warmup, job_count, workers; benchmark_ticks=100)
    elapsed = @elapsed simulate(
        :shoal_forage;
        node=:falandays,
        ticks=Int(benchmark_ticks),
        seed=_shoal_seed(block),
        n_nodes=250,
        n_agents=16,
        substeps=5,
        every=5,
        task_kwargs=(
            block=Int(block),
            association_need=true,
            conspecific_mode=:veridical,
            conspecific_range=5.0,
        ),
        record=(:needs, :poses, :interactions, :rate),
    )
    projected = elapsed * Int(ticks) / Int(benchmark_ticks) * job_count / workers
    return (elapsed_seconds=elapsed, benchmark_ticks=Int(benchmark_ticks), projected_seconds=projected)
end

function _shoal_is_diagnostic(job)
    return job.block == 1 && (job.mode === :blind || job.conspecific_range == 5.0)
end

function _shoal_save_diagnostic(path, sim)
    lock(SHOAL_DIAGNOSTIC_LOCK) do
        _shoal_atomic(path) do temporary
            JLD2.jldsave(
                temporary;
                config=sim.config,
                needs=getchannel(sim.recorder, :needs),
                poses=getchannel(sim.recorder, :poses),
                interactions=getchannel(sim.recorder, :interactions),
                rate=getchannel(sim.recorder, :rate),
                receptors=getchannel(sim.recorder, :receptors),
                effectors=getchannel(sim.recorder, :effectors),
            )
        end
    end
    return path
end

function _shoal_run_job(job, dir; ticks, warmup, record_every, diagnostics)
    id = _shoal_job_id(job)
    result_path = joinpath(dir, "jobs", id * ".toml")
    if isfile(result_path)
        existing = TOML.parsefile(result_path)
        if get(existing, "status", "") == "complete"
            println("[shoal] resume  ", id)
            return existing
        end
    end
    println("[shoal] start   ", id)
    diagnostic = diagnostics && _shoal_is_diagnostic(job)
    record = diagnostic ?
        (:needs, :poses, :interactions, :rate, :receptors, :effectors) :
        (:needs, :poses, :interactions, :rate)
    started = time()
    sim = simulate(
        :shoal_forage;
        node=:falandays,
        ticks=Int(ticks),
        window=Int(ticks) - Int(warmup),
        seed=_shoal_seed(job.block),
        n_nodes=250,
        n_agents=16,
        substeps=5,
        every=Int(record_every),
        task_kwargs=(
            block=job.block,
            association_need=job.association_need,
            conspecific_mode=job.mode,
            conspecific_range=job.conspecific_range,
        ),
        record=record,
    )
    needs = shoal_need_satisfaction(sim; warmup=Int(warmup))
    contacts = shoal_contact_summary(sim; warmup=Int(warmup))
    movement = shoal_movement_summary(sim; warmup=Int(warmup))
    group_movement = shoal_group_movement_summary(sim; warmup=Int(warmup))
    graph = shoal_perceptual_graph(sim; warmup=Int(warmup))
    row = Dict{String,Any}(
        "status" => "complete",
        "job_id" => id,
        "block" => job.block,
        "seed" => _shoal_seed(job.block),
        "association_need" => job.association_need,
        "mode" => string(job.mode),
        "conspecific_range" => job.conspecific_range,
        "ticks" => Int(ticks),
        "warmup" => Int(warmup),
        "mean_material_satisfaction" => needs.mean_material_satisfaction,
        "balanced_material_satisfaction" => needs.balanced_material_satisfaction,
        "fraction_both_satisfied" => needs.fraction_both_satisfied,
        "association_satisfaction" => something(needs.association_satisfaction, NaN),
        "mean_contact_rate" => contacts.mean_contact_rate,
        "mean_alternation_fraction" => contacts.mean_alternation_fraction,
        "contact_measure_exact" => contacts.exact,
        "contact_record_every" => contacts.record_every,
        "mean_recorded_speed" => movement.mean_recorded_speed,
        "mean_recorded_path_length" => movement.mean_recorded_path_length,
        "stationary_fraction" => movement.stationary_fraction,
        "wall_occupancy" => movement.wall_occupancy,
        "mean_nearest_neighbor_distance" => group_movement.mean_nearest_neighbor_distance,
        "largest_proximity_component_fraction" => group_movement.largest_proximity_component_fraction,
        "movement_coherence" => group_movement.movement_coherence,
        "group_translation_speed" => group_movement.group_translation_speed,
        "perceptual_graph_mean_degree" => graph.mean_degree,
        "perceptual_graph_largest_weak_component" => graph.largest_weak_component_fraction,
        "perceptual_graph_edge_turnover" => graph.edge_turnover,
        "diagnostic" => diagnostic,
        "elapsed_seconds" => time() - started,
    )
    per_agent = map(eachindex(needs.per_agent)) do index
        need = needs.per_agent[index]
        contact = contacts.per_agent[index]
        motion = movement.per_agent[index]
        (
            job_id=id,
            block=job.block,
            association_need=job.association_need,
            mode=job.mode,
            conspecific_range=job.conspecific_range,
            entity_id=need.entity_id,
            mean_material_satisfaction=need.mean_material_satisfaction,
            balanced_material_satisfaction=need.balanced_material_satisfaction,
            fraction_both_satisfied=need.fraction_both_satisfied,
            association_satisfaction=need.association_satisfaction,
            resource_1_contacts=contact.resource_1_contacts,
            resource_2_contacts=contact.resource_2_contacts,
            contact_rate=contact.contact_rate,
            alternation_fraction=contact.alternation_fraction,
            recorded_path_length=motion.recorded_path_length,
            mean_recorded_speed=motion.mean_recorded_speed,
            stationary_fraction=motion.stationary_fraction,
            wall_occupancy=motion.wall_occupancy,
        )
    end
    _shoal_write_csv(joinpath(dir, "per_agent", id * ".csv"), per_agent)
    diagnostic && _shoal_save_diagnostic(joinpath(dir, "diagnostics", id * ".jld2"), sim)
    _shoal_write_toml(result_path, row)
    println("[shoal] finish  ", id, " (", round(row["elapsed_seconds"], digits=1), "s)")
    return row
end

function _shoal_parallel_jobs(jobs, dir; workers, kwargs...)
    queue = Channel{Any}(length(jobs))
    for job in jobs
        put!(queue, job)
    end
    close(queue)
    results = Channel{Any}(length(jobs))
    tasks = [Threads.@spawn begin
        for job in queue
            try
                result = _shoal_run_job(job, dir; kwargs...)
                put!(results, (ok=true, job=job, result=result))
            catch error
                put!(results, (
                    ok=false,
                    job=job,
                    error=sprint(showerror, error, catch_backtrace()),
                ))
            end
        end
    end for _ in 1:workers]
    foreach(wait, tasks)
    close(results)
    return collect(results)
end

function _shoal_row(result)
    return (
        job_id=result["job_id"],
        block=Int(result["block"]),
        seed=Int(result["seed"]),
        association_need=Bool(result["association_need"]),
        mode=Symbol(result["mode"]),
        conspecific_range=Float64(result["conspecific_range"]),
        mean_material_satisfaction=Float64(result["mean_material_satisfaction"]),
        balanced_material_satisfaction=Float64(result["balanced_material_satisfaction"]),
        fraction_both_satisfied=Float64(result["fraction_both_satisfied"]),
        association_satisfaction=Float64(result["association_satisfaction"]),
        mean_contact_rate=Float64(result["mean_contact_rate"]),
        mean_alternation_fraction=Float64(result["mean_alternation_fraction"]),
        contact_measure_exact=Bool(get(result, "contact_measure_exact", false)),
        contact_record_every=Int(get(result, "contact_record_every", 5)),
        mean_recorded_speed=Float64(result["mean_recorded_speed"]),
        mean_recorded_path_length=Float64(result["mean_recorded_path_length"]),
        stationary_fraction=Float64(result["stationary_fraction"]),
        wall_occupancy=Float64(result["wall_occupancy"]),
        mean_nearest_neighbor_distance=Float64(result["mean_nearest_neighbor_distance"]),
        largest_proximity_component_fraction=Float64(result["largest_proximity_component_fraction"]),
        movement_coherence=Float64(result["movement_coherence"]),
        group_translation_speed=Float64(result["group_translation_speed"]),
        perceptual_graph_mean_degree=Float64(result["perceptual_graph_mean_degree"]),
        perceptual_graph_largest_weak_component=Float64(result["perceptual_graph_largest_weak_component"]),
        perceptual_graph_edge_turnover=Float64(result["perceptual_graph_edge_turnover"]),
        diagnostic=Bool(result["diagnostic"]),
        elapsed_seconds=Float64(result["elapsed_seconds"]),
    )
end

function _shoal_find(rows, block, association_need, mode, range=5.0)
    index = findfirst(row -> row.block == block &&
        row.association_need == association_need && row.mode === mode &&
        (mode === :blind || row.conspecific_range == range), rows)
    index === nothing && error("missing matched shoal condition")
    return rows[index]
end

function _shoal_contrasts(rows, blocks)
    output = NamedTuple[]
    for block in blocks, association_need in (false, true), range in SHOAL_RANGES
        blind = _shoal_find(rows, block, association_need, :blind)
        veridical = _shoal_find(rows, block, association_need, :veridical, range)
        sham = _shoal_find(rows, block, association_need, :bearing_sham, range)
        push!(output, (
            block=Int(block),
            association_need,
            conspecific_range=range,
            veridical_minus_blind=veridical.mean_material_satisfaction - blind.mean_material_satisfaction,
            veridical_minus_bearing_sham=veridical.mean_material_satisfaction - sham.mean_material_satisfaction,
            proximity_component_veridical_minus_blind=
                veridical.largest_proximity_component_fraction - blind.largest_proximity_component_fraction,
            proximity_component_veridical_minus_bearing_sham=
                veridical.largest_proximity_component_fraction - sham.largest_proximity_component_fraction,
            movement_coherence_veridical_minus_blind=
                veridical.movement_coherence - blind.movement_coherence,
            movement_coherence_veridical_minus_bearing_sham=
                veridical.movement_coherence - sham.movement_coherence,
        ))
    end
    for block in blocks, range in SHOAL_RANGES
        on = only(row for row in output if row.block == block &&
            row.association_need === true && row.conspecific_range == range)
        off = only(row for row in output if row.block == block &&
            row.association_need === false && row.conspecific_range == range)
        push!(output, (
            block=Int(block),
            association_need="on_minus_off",
            conspecific_range=range,
            veridical_minus_blind=on.veridical_minus_blind - off.veridical_minus_blind,
            veridical_minus_bearing_sham=on.veridical_minus_bearing_sham - off.veridical_minus_bearing_sham,
            proximity_component_veridical_minus_blind=
                on.proximity_component_veridical_minus_blind - off.proximity_component_veridical_minus_blind,
            proximity_component_veridical_minus_bearing_sham=
                on.proximity_component_veridical_minus_bearing_sham - off.proximity_component_veridical_minus_bearing_sham,
            movement_coherence_veridical_minus_blind=
                on.movement_coherence_veridical_minus_blind - off.movement_coherence_veridical_minus_blind,
            movement_coherence_veridical_minus_bearing_sham=
                on.movement_coherence_veridical_minus_bearing_sham - off.movement_coherence_veridical_minus_bearing_sham,
        ))
    end
    return output
end

function _shoal_aggregate(rows)
    groups = Dict{Tuple{Bool,Symbol,Float64},Vector{Any}}()
    for row in rows
        key = (row.association_need, row.mode, row.conspecific_range)
        push!(get!(groups, key, Any[]), row)
    end
    return [(
        association_need=key[1],
        mode=key[2],
        conspecific_range=key[3],
        n=length(group),
        mean_material_satisfaction=mean(row.mean_material_satisfaction for row in group),
        sd_material_satisfaction=length(group) > 1 ?
            std([row.mean_material_satisfaction for row in group]) : 0.0,
        mean_balanced_material_satisfaction=mean(row.balanced_material_satisfaction for row in group),
        mean_fraction_both_satisfied=mean(row.fraction_both_satisfied for row in group),
        mean_association_satisfaction=mean(row.association_satisfaction for row in group),
        mean_sampled_contact_rate=mean(row.mean_contact_rate for row in group),
        mean_recorded_speed=mean(row.mean_recorded_speed for row in group),
        mean_wall_occupancy=mean(row.wall_occupancy for row in group),
        mean_largest_proximity_component_fraction=mean(row.largest_proximity_component_fraction for row in group),
        mean_nearest_neighbor_distance=mean(row.mean_nearest_neighbor_distance for row in group),
        mean_movement_coherence=mean(row.movement_coherence for row in group),
        mean_group_translation_speed=mean(row.group_translation_speed for row in group),
        mean_perceptual_graph_degree=mean(row.perceptual_graph_mean_degree for row in group),
        mean_perceptual_graph_component=mean(row.perceptual_graph_largest_weak_component for row in group),
    ) for (key, group) in sort!(collect(groups); by=item -> string(first(item)))]
end

function run_shoal_vision_sweep(;
    profile=:pilot,
    root=nothing,
    resume=nothing,
    diagnostics=true,
    max_workers::Integer=4,
)
    protocol = TOML.parsefile(SHOAL_PROTOCOL_PATH)
    profile_ = _shoal_profile(profile)
    blocks = profile_ === :pilot ? Int.(protocol["pilot"]["blocks"]) : Int.(protocol["design"]["blocks"])
    ticks = profile_ === :pilot ? Int(protocol["pilot"]["ticks"]) : Int(protocol["runtime"]["ticks"])
    warmup = profile_ === :pilot ? Int(protocol["pilot"]["warmup"]) : Int(protocol["runtime"]["warmup"])
    jobs = _shoal_conditions(blocks)
    dir = if resume !== nothing
        abspath(string(resume))
    else
        run_dir("shoal_vision_sweep"; root=root === nothing ? joinpath(@__DIR__, "runs") : string(root))
    end
    mkpath(dir)
    manifest = _shoal_manifest(profile_, blocks, ticks, warmup, jobs)
    _shoal_write_toml(joinpath(dir, "manifest.toml"), manifest)
    cp(SHOAL_PROTOCOL_PATH, joinpath(dir, "protocol.toml"); force=true)
    _shoal_status!(dir, :validating)

    try
        _shoal_vertical_slice!()
    catch error
        _shoal_status!(dir, :failed_vertical_slice; details=Dict(
            "error" => sprint(showerror, error, catch_backtrace()),
        ))
        rethrow()
    end

    workers = min(Int(max_workers), Threads.nthreads(), length(jobs))
    workers >= 1 || error("max_workers must be positive")
    benchmark = _shoal_benchmark(first(blocks), ticks, warmup, length(jobs), workers)
    maximum_seconds = Float64(protocol["runtime"]["maximum_projected_seconds"])
    _shoal_write_toml(joinpath(dir, "benchmark.toml"), Dict(
        "elapsed_seconds" => benchmark.elapsed_seconds,
        "benchmark_ticks" => benchmark.benchmark_ticks,
        "projected_seconds" => benchmark.projected_seconds,
        "workers" => workers,
        "maximum_projected_seconds" => maximum_seconds,
    ))
    if benchmark.projected_seconds > maximum_seconds
        _shoal_status!(dir, :incomplete; details=Dict(
            "reason" => "projected runtime exceeds explicit limit",
            "projected_seconds" => benchmark.projected_seconds,
        ))
        error("projected shoal sweep runtime $(round(benchmark.projected_seconds, digits=1))s exceeds $(maximum_seconds)s")
    end

    _shoal_status!(dir, :running; details=Dict("jobs" => length(jobs), "workers" => workers))
    outcomes = try
        _shoal_parallel_jobs(
            jobs,
            dir;
            workers,
            ticks,
            warmup,
            record_every=Int(protocol["runtime"]["record_every"]),
            diagnostics=_shoal_bool(diagnostics),
        )
    catch error
        _shoal_status!(dir, :incomplete; details=Dict(
            "reason" => "runner interrupted or failed",
            "error" => sprint(showerror, error),
        ))
        rethrow()
    end
    failures = [outcome for outcome in outcomes if !outcome.ok]
    if !isempty(failures)
        _shoal_write_json(joinpath(dir, "failures.json"), failures)
        _shoal_status!(dir, :incomplete; details=Dict("failed_jobs" => length(failures)))
        error("$(length(failures)) shoal sweep jobs failed; see failures.json")
    end
    rows = sort!([_shoal_row(outcome.result) for outcome in outcomes]; by=row -> row.job_id)
    contrasts = _shoal_contrasts(rows, blocks)
    aggregates = _shoal_aggregate(rows)
    _shoal_write_csv(joinpath(dir, "jobs.csv"), rows)
    _shoal_write_csv(joinpath(dir, "paired_contrasts.csv"), contrasts)
    _shoal_write_csv(joinpath(dir, "figure_inputs.csv"), rows)
    _shoal_write_csv(joinpath(dir, "aggregate.csv"), aggregates)
    summary = (
        schema="brainlesslab-shoal-sweep-summary-v1",
        evidence_status=:exploratory,
        profile=profile_,
        underpowered=profile_ === :pilot,
        complete=true,
        blocks=blocks,
        ticks,
        warmup,
        jobs=length(rows),
        primary=:mean_material_satisfaction,
        aggregates,
        paired_contrasts=contrasts,
    )
    _shoal_write_json(joinpath(dir, "summary.json"), summary)
    _shoal_status!(dir, :complete; details=Dict(
        "jobs" => length(rows),
        "profile" => string(profile_),
        "underpowered" => profile_ === :pilot,
    ))
    return dir
end

register_experiment!(
    :shoal_vision_sweep,
    run_shoal_vision_sweep;
    description="Underpowered exploratory sweep of conspecific sight distance, bearing alignment, and association need in moving Falandays shoals.",
)
