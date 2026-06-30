import BrainlessLab: register_metric!

function final_error_abs(task_metrics)
    (:final_error in propertynames(task_metrics)) || return NaN
    return abs(Float64(task_metrics.final_error))
end

register_metric!(:final_error_abs, final_error_abs)
