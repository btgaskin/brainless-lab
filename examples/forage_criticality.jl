using BrainlessLab, CairoMakie, Random

let
    output_dir = get(ENV, "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR", joinpath(@__DIR__, "output"))
    mkpath(output_dir)

    specs = (
        (; kind=:turn, threshold=(:quantile, 0.85), id="turn_q85"),
        (; kind=:align, threshold=(:quantile, 0.85), neighbor_radius="vision_range", id="align_q85"),
        (; kind=:speed, threshold=(:quantile, 0.85), id="speed_q85"),
        (; kind=:graded, id="graded"),
    )

    sim = simulate(
        :forage;
        node=:falandays,
        ticks=96,
        window=96,
        seed=42,
        n_agents=4,
        n_nodes=12,
        # Default torus space_size=15.0 => max possible torus distance is
        # ~10.6 (size/sqrt(2)); vision_range=15.0 made every agent mutually
        # visible regardless of position, which pinned contact_graph_clusters
        # at n_components=1/largest_frac=1.0 for every tick (verified: no
        # variation at all, not just a washed-out average). 4.5 was checked
        # empirically to give a genuinely varying cluster signal (2-3
        # components / 0.5-0.75 largest fraction) across this run.
        vision_range=4.5,
        sensory_noise=0.0,
        record=(:spikes, :rate, :poses, :spectral_radius, :polarization, :milling),
    )

    kmax = 4
    scalar = Dict{String,Float64}(
        "sigma_mr_node" => branching_ratio_mr(sim; level=:node, kmax=kmax).m_mr,
        "susceptibility_node" => susceptibility(sim; level=:node).susceptibility,
        "susceptibility_agent" => susceptibility(sim; level=:agent).susceptibility,
        "correlation_length" => correlation_length(sim),
        "cluster_largest_component_frac" => contact_graph_clusters(sim).largest_component_frac_mean,
        "dist_to_source" => sim.metrics.mean_distance_to_source,
    )
    for spec in specs
        scalar["sigma_mr_agent__$(spec.id)"] = branching_ratio_mr(sim; level=:agent, kmax=kmax, observable=spec).m_mr
    end

    null = crossshift_null(
        sim,
        s -> susceptibility(s; level=:agent).susceptibility;
        n_shifts=5,
        rng=MersenneTwister(123),
    )
    open(joinpath(output_dir, "forage_criticality_null.csv"), "w") do io
        println(io, "measure,real,null_mean,null_std,ratio,n_shifts")
        println(io, join(("susceptibility_agent", null.real, null.null_mean, null.null_std, null.ratio, 5), ","))
    end

    centers, m_node, _, _ = branching_ratio_mr_windowed(sim; level=:node, window=24, stride=12, kmax=kmax)
    _, m_agent, _, _ = branching_ratio_mr_windowed(sim; level=:agent, window=24, stride=12, kmax=kmax, observable=specs[end])
    dist = distance_to_source(sim)

    fig = Figure(size=(800, 520))
    ax1 = Axis(fig[1, 1], xlabel="tick", ylabel="distance")
    lines!(ax1, 1:length(dist), dist)
    ax2 = Axis(fig[2, 1], xlabel="window center", ylabel="MR m")
    n_node = min(length(centers), length(m_node))
    n_agent = min(length(centers), length(m_agent))
    n_node > 0 && lines!(ax2, centers[1:n_node], m_node[1:n_node], label="node")
    n_agent > 0 && lines!(ax2, centers[1:n_agent], m_agent[1:n_agent], label="agent graded")
    axislegend(ax2, position=:rb)
    save(joinpath(output_dir, "forage_criticality.png"), fig)

    println("forage criticality scalar measures: ", join(["$(key)=$(round(value; digits=4))" for (key, value) in sort!(collect(scalar), by=first)], ", "))
    println("saved forage criticality outputs to $(output_dir)")
end
