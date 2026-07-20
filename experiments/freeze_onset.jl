# Freeze-onset across tasks  (registered as :freeze_onset)
# =======================================================
# A Falandays reservoir self-organizes online. If we FREEZE its plasticity at
# tick T, is the frozen network a working controller? There is an onset tick below
# which freezing locks in the hyper-excitable initial weights (the network
# saturates and does nothing) and above which the frozen weights work. This sweeps
# T (log-spaced, dense near the start) for each single-agent task and reports the
# onset tick, the dead/alive levels, and the effect — using normalized_score (so
# raw-score scale/direction differences across tasks don't confound the read) plus
# the frozen population rate (the crisp cross-task signal).
#
# Registered for `experiments/run.jl`; run with:
#   julia --project=. experiments/run.jl freeze_onset
#   julia --project=. experiments/run.jl freeze_onset seeds=0:9 tasks=tracking,pong

using .ExpHarness, .ExpRegistry
using BrainlessLab

const FREEZE_ONSET_DEFAULT_TICKS = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377]

function run_freeze_onset(; tasks=[:tracking, :wall, :pong],
                          freeze_ticks=FREEZE_ONSET_DEFAULT_TICKS,
                          window::Integer=600, seeds=0:5)
    jnum(x) = isfinite(x) ? string(round(x, digits=5)) : "null"
    jarr(v) = "[" * join(jnum.(v), ",") * "]"

    tasks = tasks isa Symbol ? [tasks] : collect(tasks)
    blocks = String[]
    println("=== freeze_onset ($(window)-tick window; normalized_score) ===")
    for task in tasks
        sw = freeze_sweep(task; freeze_ticks=freeze_ticks, window=window, seeds=seeds)
        on = onset_tick(freeze_ticks, sw.fz_mean)
        resolved = on.drop > 0.03
        push!(blocks, "\"$task\":{" *
            "\"freeze\":{\"mean\":$(jarr(sw.fz_mean)),\"sd\":$(jarr(sw.fz_sd))}," *
            "\"full\":{\"mean\":$(jarr(sw.fl_mean))}," *
            "\"rate\":{\"mean\":$(jarr(sw.rate_mean)),\"sd\":$(jarr(sw.rate_sd))}," *
            "\"raw\":{\"mean\":$(jarr(sw.raw_mean))}," *
            "\"fraction\":$(jarr(on.fraction))," *
            "\"dead\":$(jnum(on.dead)),\"alive\":$(jnum(on.alive)),\"drop\":$(jnum(on.drop))," *
            "\"onset\":$(jnum(on.onset)),\"resolved\":$(resolved)," *
            "\"dead_rate\":$(jnum(sw.rate_mean[1])),\"alive_rate\":$(jnum(sw.rate_mean[end]))}")
        println("[$task]  dead=", round(on.dead, digits=3), "  alive=", round(on.alive, digits=3),
                "  drop=", round(on.drop, digits=3),
                "  onset=", (resolved && !isnan(on.onset)) ? string(Int(on.onset)) : "unresolved",
                "  dead_rate=", round(sw.rate_mean[1], digits=3),
                "  alive_rate=", round(sw.rate_mean[end], digits=3))
    end

    json = "{\n\"experiment\":\"freeze_onset\",\"node\":\"falandays\"," *
           "\"window\":$window,\"nseeds\":$(length(seeds)),\"verb\":\"freeze_plasticity\"," *
           "\"freeze_ticks\":$(jarr(Float64.(collect(freeze_ticks)))),\n\"tasks\":{\n" *
           join(blocks, ",\n") * "\n}\n}\n"

    dir = run_dir("freeze_onset")
    write_text(dir, "results.json", json)
    write_text(dir, "manifest.txt",
        "experiment = freeze_onset\nnode = falandays\ntasks = $(collect(tasks))\n" *
        "freeze_ticks = $(collect(freeze_ticks))\nwindow = $window\nseeds = $(collect(seeds))\n" *
        "verb = freeze_plasticity\ngit = $(git_sha())\nstamp = $(stamp())\n")
    return dir
end

register_experiment!(:freeze_onset, run_freeze_onset;
    description="Freeze plasticity at tick T across single-agent tasks; find the dead→alive onset (normalized score + rate).")
