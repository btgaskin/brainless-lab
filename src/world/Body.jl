"""
    PassthroughBody()

Stateless body for task environments that already expose reservoir-shaped
percepts and accept reservoir-shaped motor commands.
"""
struct PassthroughBody <: Body end

receptors(::PassthroughBody, percept) = percept

motor(::PassthroughBody, e) = e
