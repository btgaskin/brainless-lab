using LinearAlgebra

const PROBE_DECODER_OPTIONS = (points=(:cue_end, :delay_end, :response),
    fit_trials=256, validation_trials=128, evaluation_trials=256,
    lambdas=(1e-4, 1e-2, 1.0, 100.0), split_seed=701, permutation_seed=702)

const _DECODABLE_PROBES = (:delayed_cue, :recall_interference, :delayed_xor,
    :evidence_accumulation, :context_integration, :temporal_order)

function _probe_trial_split(n; fit_trials, validation_trials, evaluation_trials, split_seed)
    counts = (_probe_integer(fit_trials, :fit_trials; minimum=2),
        _probe_integer(validation_trials, :validation_trials; minimum=2),
        _probe_integer(evaluation_trials, :evaluation_trials; minimum=2))
    sum(counts) == n || throw(ArgumentError(
        "decoder requires exactly $(sum(counts)) whole trials in each block; got $n"))
    order = randperm(MersenneTwister(split_seed), n)
    a, b, c = counts
    return (fit=order[1:a], validation=order[a + 1:a + b], evaluation=order[a + b + 1:a + b + c])
end

_probe_predictions(X, weights, intercept) = [x >= 0 ? 1 : 2 for x in X * weights .+ intercept]
_probe_accuracy(predicted, truth) = sum(predicted .== truth) / length(truth)

function _probe_ridge(X, y, split, lambdas)
    fit = split.fit
    centre = vec(mean(X[fit, :]; dims=1))
    scale = vec(std(X[fit, :]; dims=1, corrected=false))
    scale[scale .== 0] .= 1
    Z = (X .- centre') ./ scale'
    targets = ifelse.(y[fit] .== 1, 1.0, -1.0)
    intercept = mean(targets)
    gram = Z[fit, :]' * Z[fit, :]
    rhs = Z[fit, :]' * (targets .- intercept)
    best = nothing
    for lambda in lambdas # sorted ascending: an exact tie keeps the smaller λ
        weights = (gram + lambda * I) \ rhs
        predicted = _probe_predictions(Z, weights, intercept)
        accuracy = _probe_accuracy(predicted[split.validation], y[split.validation])
        if best === nothing || accuracy > best.validation_accuracy
            best = (; lambda, weights, intercept, centre, scale, predicted,
                validation_accuracy=accuracy)
        end
    end
    return best
end

function _probe_decode(X::AbstractMatrix, y, native;
    fit_trials=256, validation_trials=128, evaluation_trials=256,
    lambdas=(1e-4, 1e-2, 1.0, 100.0), split_seed=701, permutation_seed=702)
    size(X, 1) == length(y) == length(native) || throw(DimensionMismatch(
        "decoder features, labels and native scores must align by whole trial"))
    size(X, 2) > 0 && all(isfinite, X) || throw(ArgumentError("decoder requires finite node features"))
    all(x -> x in (1, 2), y) || throw(ArgumentError("probe decoder requires labels 1 and 2"))
    all(x -> x isa Real && isfinite(x) && 0 <= x <= 1, native) ||
        throw(ArgumentError("decoder requires completed native outcomes on every trial"))
    grid = sort!(unique(Float64.(collect(lambdas))))
    !isempty(grid) && all(x -> isfinite(x) && x > 0, grid) ||
        throw(ArgumentError("decoder lambdas must be finite and positive"))
    split = _probe_trial_split(length(y); fit_trials, validation_trials, evaluation_trials, split_seed)
    for (name, indices) in pairs(split)
        length(unique(y[indices])) == 2 || throw(ArgumentError(
            "decoder $name split needs both classes; increase trials or revise the declared split seed"))
    end
    fitted = _probe_ridge(X, y, split, grid)
    permuted = copy(y)
    rng = MersenneTwister(permutation_seed)
    # Shuffle fit and validation labels separately. Never permute evaluation
    # truth into training, and tune this null by the same validation procedure.
    for indices in (split.fit, split.validation)
        permuted[indices] = shuffle(rng, y[indices])
    end
    null = _probe_ridge(X, permuted, split, grid)
    constant = sum(y[split.fit] .== 1) >= length(split.fit) / 2 ? 1 : 2
    test = split.evaluation
    statistics = (accuracy=_probe_accuracy(fitted.predicted[test], y[test]),
        native_accuracy=mean(native[test]), constant_accuracy=mean(y[test] .== constant),
        permutation_accuracy=_probe_accuracy(null.predicted[test], y[test]),
        chance_accuracy=0.5, feature_count=size(X, 2), fit_trials=length(split.fit),
        validation_trials=length(split.validation), evaluation_trials=length(test),
        lambda=fitted.lambda, permutation_lambda=null.lambda,
        validation_accuracy=fitted.validation_accuracy, independent_blocks=1)
    return (; statistics, fitted, null, constant, split)
end

"""
    probe_decodability(block::ProfileBlock; points, fit_trials, validation_trials,
        evaluation_trials, lambdas, split_seed, permutation_seed)

Fit a regularised linear diagnostic to one fixed reservoir wiring per block.
Register/use this analysis with `scope=:block`, `construction_scope=:block`,
`reset=:full` and `record_every=1`. It consumes sparse `:probe_events`.

Splits contain whole trials and are shared across observation points. Scaling
uses fit trials only; the ridge parameter uses validation trials only. Reported
accuracy and matched native accuracy use evaluation trials only. The decoder
does not drive the task. Reversal adaptation and physical control are excluded.
"""
function probe_decodability(block::ProfileBlock;
    points=(:cue_end, :delay_end, :response), kwargs...)
    evaluation = block.evaluation
    evaluation.construction_scope === :block && evaluation.reset === :full ||
        throw(ArgumentError("probe decoder requires construction_scope=:block and reset=:full"))
    trials = sort!(collect(block.trials); by=t -> t.trial)
    isempty(trials) && throw(ArgumentError("probe decoder requires trials"))
    all(t -> t.block == block.block && t.condition == block.condition, trials) ||
        throw(ArgumentError("probe decoder cannot combine blocks or conditions"))
    allunique([t.trial for t in trials]) || throw(ArgumentError("duplicate decoder trial IDs"))
    first_trial = first(trials)
    task = first_trial.simulation.task
    task in _DECODABLE_PROBES ||
        throw(ArgumentError("probe decoder supports stimulus-driven binary probes only"))
    topology = Tuple(seed.topology for seed in first_trial.seeds)
    all(t -> t.simulation.task === task && t.simulation.node === first_trial.simulation.node &&
        t.simulation.config.parameters == first_trial.simulation.config.parameters &&
        t.simulation.config.interface == first_trial.simulation.config.interface &&
        t.simulation.config.evaluation.construction_scope === :block &&
        t.simulation.config.evaluation.reset === :full &&
        Tuple(s.topology for s in t.seeds) == topology, trials) ||
        throw(ArgumentError("decoder trials must share task, node, parameters, interface and block wiring"))
    allunique([first(t.seeds).world for t in trials]) ||
        throw(ArgumentError("decoder trials require distinct world seeds"))
    points_ = Tuple(Symbol.(points))
    !isempty(points_) && allunique(points_) &&
        all(p -> p in (:cue_end, :delay_end, :response), points_) ||
        throw(ArgumentError("decoder points must be distinct cue_end, delay_end or response"))
    statistics = Pair{Symbol,Float64}[]
    scores, predictions, coefficients = NamedTuple[], NamedTuple[], NamedTuple[]
    for point in points_
        events = map(trials) do trial
            candidates = filter(e -> e.point === point,
                getchannel(trial.simulation.recorder, :probe_events))
            length(candidates) == 1 || throw(ArgumentError(
                "decoder needs exactly one $point observation per trial"))
            only(candidates)
        end
        reference = first(events)
        length(reference.features) == 1 || throw(ArgumentError("probe decoder requires one reservoir per trial"))
        all(e -> e.task === task && e.channel === :emitted_activity && e.round == 1 &&
            e.features.ids == reference.features.ids && length(e.features) == 1 &&
            length(only(e.features)) == length(only(reference.features)), events) ||
            throw(ArgumentError("incompatible probe feature channels, entity IDs or node counts"))
        X = reduce(vcat, permutedims(only(e.features)) for e in events)
        y = [e.label for e in events]
        native = [task_outcome(t.simulation).raw for t in trials]
        decoded = _probe_decode(X, y, native; kwargs...)
        push!(scores, merge((; task, point, channel=:emitted_activity), decoded.statistics))
        for (name, value) in pairs(decoded.statistics)
            push!(statistics, Symbol(point, :__, name) => Float64(value))
        end
        for (split, indices) in pairs(decoded.split), i in indices
            push!(predictions, (point, trial=trials[i].trial, split, label=y[i],
                prediction=decoded.fitted.predicted[i], native_accuracy=native[i],
                constant_prediction=decoded.constant, permutation_prediction=decoded.null.predicted[i]))
        end
        for (model, fit) in ((:decoder, decoded.fitted), (:permutation, decoded.null))
            for i in eachindex(fit.weights)
                push!(coefficients, (point, model, feature=i, weight=fit.weights[i],
                    centre=fit.centre[i], scale=fit.scale[i], intercept=fit.intercept,
                    lambda=fit.lambda))
            end
        end
    end
    return BlockAnalysisResult(; statistics=(; statistics...),
        tables=(probe_decoders=scores, probe_predictions=predictions, probe_coefficients=coefficients))
end

function _validate_profile_analysis(::typeof(probe_decodability), target, options)
    target.composition.task in _DECODABLE_PROBES || throw(ArgumentError(
        "probe decoder supports stimulus-driven binary probes only"))
    evaluation = target.evaluation
    evaluation.construction_scope === :block && evaluation.reset === :full ||
        throw(ArgumentError("probe decoder requires construction_scope=:block and reset=:full"))
    _probe_trial_split(evaluation.trials_per_block;
        fit_trials=options[:fit_trials], validation_trials=options[:validation_trials],
        evaluation_trials=options[:evaluation_trials], split_seed=options[:split_seed])
    points = Tuple(Symbol.(options[:points]))
    !isempty(points) && allunique(points) &&
        all(p -> p in (:cue_end, :delay_end, :response), points) ||
        throw(ArgumentError("decoder points must be distinct cue_end, delay_end or response"))
    lambdas = options[:lambdas]
    !isempty(lambdas) && all(x -> x isa Real && isfinite(x) && x > 0, lambdas) ||
        throw(ArgumentError("decoder lambdas must be finite and positive"))
    return nothing
end
