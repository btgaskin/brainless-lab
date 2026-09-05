using BrainlessLab

# One implementation diagnostic, not a performance estimate.
composition = CompositionSpec(:delayed_cue_example, :falandays, :delayed_cue;
    n_nodes=200, parameters=copy(DIRECT_CONTROL_FALANDAYS_PROFILE.parameters))
target = EvaluationTarget(:delayed_cue_example, composition,
    EvaluationSpec(blocks=4, horizon=144, root_seed=941_001))
result = evaluate(target)
for trial in result.trials
    println((block=trial.block, initial_state=trial.initial_state,
        outcome=task_outcome(trial.simulation)))
end
