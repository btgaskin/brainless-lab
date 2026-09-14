using BrainlessLab

"""Author the programme; this function performs no simulations."""
function build_programme(destination=joinpath(@__DIR__, "programme"); smoke=false)
    scales = smoke ? (0.01, 1.0) : (0.01, 0.1, 1.0)
    blocks = smoke ? 2 : 4
    regimes = ((:both_on,true,true), (:weights_off,false,true),
               (:targets_off,true,false), (:both_off,false,false))
    function target(id, base, scale, weights, targets, evaluation; options=base.task_options)
        parameters = merge(base.parameters, Dict(:recurrent_init_scale=>scale))
        weights || (parameters[:lrate_wmat]=0.0)
        targets || (parameters[:lrate_targ]=0.0)
        composition = CompositionSpec(id,base.node,base.task;n_nodes=base.n_nodes,
            body=base.body,parameters,task_options=options,body_options=base.body_options,
            interface=base.interface,interaction_cycle=base.interaction_cycle)
        return EvaluationTarget(id,composition,evaluation)
    end
    sentences = smoke ? 10 : 1000
    word_base = CompositionSpec(:words,:falandays,:word_sequence_2021;n_nodes=smoke ? 16 : 100,
        parameters=Dict(:weight_init_mode=>:legacy_normal,:weight_init_std=>1.0,
            :input_weight=>5.0,:leak=>0.25,:lrate_wmat=>0.1,:lrate_targ=>0.01,
            :rectify=>true,:repair_masks=>false))
    conditions = EvaluationTarget[]
    profiles = BrainlessLab.AbstractOperationPlan[]
    completions = smoke ? ((1,1),) : ((0,1),(1,1),(1,2),(2,1),(2,2))
    for (i,scale) in enumerate(scales), (regime,weights,targets) in regimes, (cues,subject) in completions
        id=Symbol(:words_s,i,:_,regime,:_cue,cues,:_subject,subject)
        evaluation=EvaluationSpec(blocks=blocks,horizon=4sentences+(cues>0 ? 4 : 0),
            warmup=0,root_seed=2026091601,construction_scope=:trial,reset=:full)
        t=target(id,word_base,scale,weights,targets,evaluation;
            options=Dict(:sentences=>sentences,:completion_cues=>cues,:completion_subject=>subject))
        push!(conditions,t)
        push!(profiles,ProfilePlan(id,t;analyses=(:word_sequence_diagnostics,)))
    end
    words=ExperimentSpec(:words,v"1.0.0";title="Word responses and completion",
        question="Does initial recurrent scale change response and completion patterns when weight or target adaptation is disabled?",
        description="Replay a probabilistic word grammar, then present a partial sentence. Compare spike rasters, pre-update homeostatic error, source-style context correlations and supplementary late-training lexical templates. There is no scalar task score.",
        conditions=Tuple(conditions),operations=Tuple(profiles),evidence_state=:planned,
        limitations=("Source-equation conformance is distinct from notebook or numerical paper replication.",
            "Completion conditions rebuild paired training histories; Python random-number identity and notebook state carryover are not reproduced.",
            "Completion presents the common verb deterministically for two-cue probes; the notebook draws it from the grammar.",
            "Completion retains each condition's adaptation policy; no shared checkpoint preparation is implied."))
    task_nodes=ExperimentSpec[]
    for task in (smoke ? (:wall,) : (:wall,:tracking,:pong))
        base=composition_spec(DEFAULT_REGISTRY,Symbol(:falandays_,task))
        horizon=resolve_task(task).minimum_scored_ticks
        evaluation=EvaluationSpec(blocks=blocks,horizon=horizon,warmup=0,
            root_seed=2026091701,construction_scope=:trial,reset=:full)
        cases=BenchmarkCasePlan[]; conditions=EvaluationTarget[]
        for (i,scale) in enumerate(scales)
            group=Tuple(target(Symbol(task,:_s,i,:_,regime),base,scale,weights,targets,evaluation)
                        for (regime,weights,targets) in regimes)
            append!(conditions,group)
            push!(cases,BenchmarkCasePlan(Symbol(:scale_,i),group;baseline=first(group).id))
        end
        push!(task_nodes,ExperimentSpec(task,v"1.0.0";title="$(uppercasefirst(String(task))): scale and updates",
            question="At each initial scale, how do raw task performance and paired differences change when weight and target updates are disabled?",
            description="Start the task at tick 1. Score the whole declared interval with no discarded warm-up. Cross recurrent scale with the four weight/target update policies, pairing worlds and initial wiring within blocks.",
            conditions=Tuple(conditions),operations=(BenchmarkPlan(Symbol(task,:_comparison),Tuple(cases)),),
            evidence_state=:planned,metadata=(scales=scales,independent_unit=:block),
            limitations=("$(blocks) development blocks demonstrate execution and describe variation; they do not establish equivalence or confirm the hypothesis.",
                "Task-native scores and applicable anchor-relative scores are reported separately; no cross-task aggregate is defined.",
                "These are declared lab reference configurations, not Marc's unspecified experimental settings.")))
    end
    question(id,title,text;description="",children=())=ExperimentSpec(id,v"1.0.0";
        title,question=text,description,children,evidence_state=:planned)
    reproduction=question(:reproduction,"Reproduce the proposed comparison",
        "Can a smaller recurrent initialisation scale reduce or reverse the apparent advantage of adaptation?";
        children=(words,task_nodes...))
    capacities=question(:capacities,"Extend across capacity probes",
        "For which capacities does the same comparison hold?";
        description="Select probes by the capacity question, verify task opportunity and decoder train/test splits, then hold wiring, input exposure and readout procedure fixed across update policies. Existing capacity-proposal files are drafts, not executed branches.")
    freeze=question(:freeze_timing,"When can adaptation stop?",
        "How long must weight or target adaptation remain active to preserve later performance?";
        description="First measure a coarse freeze-time curve from raw starts, including never adapting and always adapting. Retain whole-run trajectories and a fixed later scoring window. Choose a task-specific acceptable loss before refining a knee; do not assume monotonicity or use binary search by default.")
    swap=question(:eye_swap,"Tracking after a left/right eye swap",
        "Does continued adaptation help recover after the sensory mapping changes?";
        description="Specify an exact mid-run mapping swap, a matched sham, update policies and separate pre-change, immediate-loss and recovery windows. Keep this distinct from swapping action channels or changing the world.")
    benchmark=question(:current_benchmark,"Extend to the current benchmark",
        "Does the effect persist in Tracking, Pong, Plank CartPole Easy and delayed cue?";
        description="Check horizon, reset, episode structure and scoring anchors for each task before adding operations. Wall belongs to the historical comparison, not the current core benchmark.")
    root=ExperimentSpec(smoke ? :adaptation_conformance : :initialisation_adaptation,v"1.0.0";
        title=smoke ? "Adaptation programme: software conformance" : "Initialisation and continued adaptation",
        question="Does plasticity establish a useful operating range, sustain task performance, or both?",
        description="Begin with the comparison suggested by Marc Bacvanski, using explicitly declared settings. Grow outward into task scope, adaptation timing and recovery after change. Each branch owns its protocol and evidence state; discussion and run attachments are recorded separately.",
        objectives=("Separate recurrent weight adaptation from target adaptation.",
                    "Preserve a traceable path from each question to its settings, trials, analyses and interpretation."),
        hypotheses=("Smaller initial recurrent weights may make frozen networks competitive on some tasks.",),
        evidence_state=:planned,children=(reproduction,benchmark,capacities,freeze,swap),
        limitations=("Marc's email supplies a hypothesis, not enough information for an exact replication of his runs.",
            "This programme is exploratory. Follow-up protocols and confirmation seeds must be registered separately."))
    write_experiment(destination,root)
    return destination
end

if abspath(PROGRAM_FILE)==@__FILE__
    println(build_programme())
end
