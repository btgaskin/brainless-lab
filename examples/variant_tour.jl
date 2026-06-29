using BrainlessLab, CairoMakie

let
    output_dir = get(ENV, "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR", joinpath(@__DIR__, "output"))
    mkpath(output_dir)

    function mean_sample(sample)
        values = Float64.(vec(collect(sample)))
        return isempty(values) ? 0.0 : sum(values) / length(values)
    end

    function rate_trace(sim)
        return [mean_sample(sample) for sample in getchannel(sim.recorder, :rate)]
    end

    function no_input_trace(node::Symbol; ticks::Integer=220, seed::Integer=91)
        reservoir = resolve_node(node)(100, 2, 2; seed=seed)
        rates = Float64[]
        for _ in 1:ticks
            spikes = step!(reservoir, zeros(2))
            push!(rates, sum(spikes) / length(spikes))
        end
        return rates
    end

    ticks = 220
    base = simulate(:wall; node=:falandays, ticks=ticks, seed=11)
    oosawa = simulate(:wall; node=:falandays_oosawa, ticks=ticks, seed=11)
    dale = simulate(:wall; node=:falandays_dale, ticks=ticks, seed=11)
    oosawa_endogenous = no_input_trace(:falandays_oosawa; ticks=ticks, seed=11)

    fig = Figure(size=(900, 560))
    ax_rate = Axis(fig[1, 1]; xlabel="tick", ylabel="population firing rate", title="Variant firing rates")
    lines!(ax_rate, rate_trace(base); label="falandays")
    lines!(ax_rate, rate_trace(oosawa); label="oosawa with wall input")
    lines!(ax_rate, oosawa_endogenous; label="oosawa no input")
    lines!(ax_rate, rate_trace(dale); label="dale + oosawa")
    axislegend(ax_rate)

    ax_score = Axis(fig[2, 1]; xlabel="variant", ylabel="wall score", title="Short-run score")
    scores = [base.metrics.score, oosawa.metrics.score, dale.metrics.score]
    labels = ["base", "oosawa", "dale"]
    barplot!(ax_score, 1:3, scores)
    ax_score.xticks = (1:3, labels)

    save(joinpath(output_dir, "variant_tour.png"), fig)

    println("variant scores base=$(round(base.metrics.score; digits=3)) oosawa=$(round(oosawa.metrics.score; digits=3)) dale=$(round(dale.metrics.score; digits=3))")
    println("saved figures to $(output_dir)")
end
