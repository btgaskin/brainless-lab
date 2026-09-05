using BrainlessLab, Random, Statistics, TOML

"""Warmed kernel costs and paired synthetic input sensitivity; development diagnostics only."""
function profile_ctrnn(; output="benchmarks/ctrnn-readiness/development")
    source_sha = readchomp(`git rev-parse HEAD`)
    source_state = isempty(readchomp(`git status --porcelain`)) ? "clean" : "dirty"
    mkpath(output)
    costs = NamedTuple[]
    responses = NamedTuple[]
    selections = Dict{String,Any}()
    for (node, family) in ((:compartmental_structured, BrainlessLab.StructuredCompartmental),
        (:compartmental_dense, BrainlessLab.DenseCompartmental))
        constructor = node === :compartmental_structured ?
            BrainlessLab._compartmental_structured_native : BrainlessLab._compartmental_dense_native
        for count in (60, 200)
            reservoir = constructor(count, 8, 2; seed=993_003)
            input = ones(8)
            spikes = step!(reservoir, input)
            effectors(reservoir, spikes)
            allocation = @allocated step!(reservoir, input)
            output_allocation = @allocated effectors(reservoir, spikes)
            timings = [@elapsed step!(reservoir, input) for _ in 1:101]
            report = BrainlessLab.resource_report(reservoir)
            push!(costs, (; node, n_nodes=count, substeps=reservoir.substeps,
                dendrites=reservoir.wiring.K, step_bytes=allocation,
                effector_bytes=output_allocation, median_step_seconds=median(timings),
                report.internal_states, report.integration_updates_per_frame))
        end
        for scale in (0.25, 0.5, 1.0, 2.0), sample in 1:24
            coordinates = scale .* randn(MersenneTwister(993_002 + sample), paramdim(family))
            model = unpack_params(family, coordinates)
            left = constructor(200, 8, 2; genome=model, seed=993_003)
            right = constructor(200, 8, 2; genome=model, seed=993_003)
            finite = true
            delta = 0.0
            total = 0.0
            equal_outputs = true
            try
                for tick in 1:120
                    a = effectors(left, step!(left, zeros(8)))
                    b = effectors(right, step!(right, ones(8)))
                    if tick > 20
                        delta = max(delta, maximum(abs.(a .- b)))
                        total += sum(a) + sum(b)
                        equal_outputs &= a[1] == a[2] && b[1] == b[2]
                    end
                end
            catch error
                error isa BrainlessLab.NonfiniteDynamics || rethrow()
                finite = false
            end
            push!(responses, (; node, scale, sample, finite,
                responsive=finite && delta > 1e-12, max_effector_difference=delta,
                silent=finite && total == 0, equal_outputs,
                mean_effector_rate=total / 400))
        end
        fractions = [(scale=scale,
            fraction=count(row -> row.node === node && row.scale == scale && row.responsive, responses) / 24)
            for scale in (0.25, 0.5, 1.0, 2.0)]
        chosen = first(sort(fractions; by=row -> (-row.fraction, row.scale)))
        selections[String(node)] = Dict("scale" => chosen.scale, "responsive_fraction" => chosen.fraction)
        println((; node, chosen...))
    end
    BrainlessLab._write_csv(joinpath(output, "kernel-costs.csv"), costs)
    BrainlessLab._write_csv(joinpath(output, "initialisation-responses.csv"), responses)
    open(joinpath(output, "initialisation.toml"), "w") do io
        TOML.print(io, Dict("evidence_state" => "exploratory", "nodes" => selections,
            "julia_version" => string(VERSION), "samples_per_scale" => 24,
            "source_sha" => source_sha, "source_state" => source_state); sorted=true)
    end
    return selections
end

abspath(PROGRAM_FILE) == (@__FILE__) && profile_ctrnn()
