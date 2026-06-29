### A Pluto.jl notebook ###
# v0.20.0

using Markdown
using InteractiveUtils

# ╔═╡ 0c8d80de-8c08-4ef8-bb4e-fec13fd473df
begin
    using BrainlessLab
    using CairoMakie
end

# ╔═╡ 8f0a8b5e-7d03-4e42-8975-93df0978fe9d
begin
    ticks = 300
    output_dir = joinpath(@__DIR__, "..", "output")
    mkpath(output_dir)
end

# ╔═╡ d7e5aa79-2ac1-4593-8a55-663ba5efc8fc
sim = simulate(:wall; node=:falandays, ticks=ticks)

# ╔═╡ 9d60bb22-6a39-4de9-9386-196b9402d477
fig = visualize(sim)

# ╔═╡ 43d1f267-0a82-4593-9a72-fb2a8f71f2d0
begin
    save(joinpath(output_dir, "pluto_quickstart.png"), fig)
    sim.metrics.score
end

# ╔═╡ 7b2e9dc9-7828-43ef-bb04-c41155e47f93
md"Slider stub: replace `ticks = 300` with a PlutoUI `@bind ticks Slider(...)` cell when PlutoUI is available."

# ╔═╡ Cell order:
# ╠═0c8d80de-8c08-4ef8-bb4e-fec13fd473df
# ╠═8f0a8b5e-7d03-4e42-8975-93df0978fe9d
# ╠═d7e5aa79-2ac1-4593-8a55-663ba5efc8fc
# ╠═9d60bb22-6a39-4de9-9386-196b9402d477
# ╠═43d1f267-0a82-4593-9a72-fb2a8f71f2d0
# ╟─7b2e9dc9-7828-43ef-bb04-c41155e47f93
