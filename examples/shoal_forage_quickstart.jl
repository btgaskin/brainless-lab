using BrainlessLab

"""
Run a small shoal-foraging simulation that exercises sector vision and
antagonistic turning.

This example is a component smoke test, not an evidence-producing experiment.
"""
function run_shoal_forage_quickstart(;
    ticks::Integer=25,
    seed::Integer=23,
    n_nodes::Integer=40,
    n_agents::Integer=4,
)
    return simulate(
        :shoal_forage;
        node=:falandays,
        ticks=Int(ticks),
        seed=Int(seed),
        n_nodes=Int(n_nodes),
        n_agents=Int(n_agents),
        task_kwargs=(
            block=2,
            association_need=true,
            conspecific_mode=:veridical,
            conspecific_range=5.0,
        ),
        record=(:needs, :poses, :interactions, :rate),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    sim = run_shoal_forage_quickstart()
    outcome = task_outcome(sim)
    println(
        "shoal forage $(outcome.key): raw=$(round(outcome.raw; digits=3)), " *
        "normalized=$(round(outcome.normalized; digits=3))",
    )
end
