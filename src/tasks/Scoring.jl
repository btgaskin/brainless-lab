@enum AnchorKind ANALYTIC NULL_MEASURED REFERENCE_MEASURED

struct ScoreAnchor
    value::Float64
    kind::AnchorKind
    provenance::String
end

analytic(v; note="") = ScoreAnchor(Float64(v), ANALYTIC, String(note))
null_anchor(v, prov) = ScoreAnchor(Float64(v), NULL_MEASURED, String(prov))
reference_anchor(v, prov) = ScoreAnchor(Float64(v), REFERENCE_MEASURED, String(prov))

function _normalized_anchor_result(
    raw_score::Real,
    floor::Real,
    ceiling::Real,
    label,
)
    ceiling <= floor &&
        throw(ArgumentError("score_ceiling must exceed score_floor for $(label)"))
    scaled = (Float64(raw_score) - Float64(floor)) / (Float64(ceiling) - Float64(floor))
    bound = scaled <= 0.0 ? :floor : scaled >= 1.0 ? :ceiling : :none
    return (value=clamp(scaled, 0.0, 1.0), bound)
end

function _normalized_anchor_score(
    raw_score::Real,
    floor::ScoreAnchor,
    ceiling::ScoreAnchor,
    label,
)
    return _normalized_anchor_result(raw_score, floor.value, ceiling.value, label).value
end

function _coerce_score_anchor(anchor::ScoreAnchor, role::Symbol, task_name::Symbol)
    return anchor
end

function _coerce_score_anchor(value::Real, role::Symbol, task_name::Symbol)
    @warn "TaskSpec $(role) for :$(task_name) was passed as a bare literal; wrapping as an uncalibrated legacy analytic anchor" maxlog = 1 _id = (:uncalibrated_score_anchor, task_name)
    return analytic(Float64(value); note="legacy literal (uncalibrated)")
end

function _task_anchor(
    task_name::Symbol,
    role::Symbol,
    anchor,
    legacy_anchor,
    default_anchor::ScoreAnchor,
)
    if anchor !== nothing && legacy_anchor !== nothing
        throw(ArgumentError("TaskSpec :$(task_name) received both $(role) and score_$(role)"))
    end
    raw = anchor !== nothing ? anchor : legacy_anchor !== nothing ? legacy_anchor : default_anchor
    return _coerce_score_anchor(raw, role, task_name)
end
