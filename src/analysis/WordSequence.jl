"""Original-style response and completion diagnostics; no scalar task objective.

Correlations compare completion activity with lexical templates from the final 100
training sentences. Undefined correlations remain NaN, rather than being scored as zero.
"""
function word_sequence_diagnostics(sim::SimResult)
    sim.task === :word_sequence_2021 || throw(ArgumentError("word diagnostics require word_sequence_2021"))
    get(sim.config, :every, 1) == 1 || throw(ArgumentError("word diagnostics require every neural tick"))
    spikes = getchannel(sim.recorder, :spikes)
    errors = getchannel(sim.recorder, :errors)
    total = length(spikes)
    train = sim.metrics.training_ticks
    total >= train || throw(ArgumentError("word diagnostics require a complete training sequence"))
    activity = hcat((_node_state_channel_vector(x, :spikes, i) for (i, x) in enumerate(spikes))...)
    mean_error = [mean(_node_state_channel_vector(errors[i], :errors, i)) for i in 1:total]
    mean_absolute_error = [mean(abs, _node_state_channel_vector(errors[i], :errors, i)) for i in 1:total]
    series = AnalysisSeries[
        AnalysisSeries(:responses, :tick, collect(1:total),
            (spike_count=vec(sum(activity; dims=1)), mean_target_error=mean_error,
             mean_absolute_target_error=mean_absolute_error)),
    ]
    # Preserve early and late node responses for source-style raster inspection.
    ticks=sort!(unique(vcat(collect(1:min(32,train)),collect(max(1,train-39):total))))
    for node in axes(activity,1)
        push!(series,AnalysisSeries(Symbol(:raster_node_,node),:tick,ticks,
            (spike=activity[node,ticks],)))
    end
    first_late = max(1, train - 399)
    stream = sim.metrics.word_stream
    templates = [begin
        indices = [i for i in first_late:train if _WORD_LEXEMES[stream[i]] == lexeme]
        isempty(indices) ? fill(NaN, size(activity, 1)) : vec(mean(activity[:, indices]; dims=2))
    end for lexeme in 1:5]
    if total > train
        # The source's completion figure correlates the last three full sentences
        # and four completion ticks, rather than lexical mean templates.
        context=activity[:,train-11:train+4]
        pairs=[(i,j) for i in 1:16 for j in 1:i]
        correlation=[std(context[:,i])>0 && std(context[:,j])>0 ?
                     cor(context[:,i],context[:,j]) : NaN for (i,j) in pairs]
        push!(series,AnalysisSeries(:completion_context_matrix,:pair,collect(eachindex(pairs)),
            (correlation=correlation,row=Float64.(first.(pairs)),column=Float64.(last.(pairs)),)))
        correlations = [begin
            x, y = activity[:, train + tick], templates[lexeme]
            std(x) > 0 && std(y) > 0 ? cor(x, y) : NaN
        end for tick in 1:4, lexeme in 1:5]
        for lexeme in 1:5
            push!(series, AnalysisSeries(Symbol(:completion_lexeme_, lexeme), :completion_tick,
                collect(1:4), (correlation=correlations[:, lexeme],)))
        end
    end
    return AnalysisResult(statistics=(mean_spike_count=mean(sum(activity; dims=1)),), series=Tuple(series))
end
