using BrainlessLab, Test, TOML
using BrainlessLab: experiment_branch, attach_experiment_run!, add_experiment_note!, render_experiment

@testset "growing experiment tree" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    target = EvaluationTarget(:tiny,
        CompositionSpec(:tiny, :null_random, :tracking; n_nodes=8),
        EvaluationSpec(horizon=2, root_seed=7341))
    child = ExperimentSpec(:comparison, v"1.0.0"; title="Comparison", question="Does it differ?",
        conditions=(target,), operations=(ProfilePlan(:profile, target),))
    future = ExperimentSpec(:future, v"1.0.0"; title="Later", question="Where else?", evidence_state=:planned)
    root = ExperimentSpec(:programme, v"1.0.0"; title="A <study>", question="When?",
        description="A growing question", hypotheses=("Maybe",), children=(child, future))
    @test experiment_branch(root, "comparison") === child
    @test_throws ArgumentError experiment_branch(root, "../comparison")
    @test_throws ArgumentError ExperimentSpec(:bad,v"1.0.0"; title="Bad", question="?", children=(child,child))
    mktempdir() do directory
        protocol = joinpath(directory, "protocol")
        write_experiment(protocol, root; registry)
        parsed = read_experiment(protocol; registry)
        @test parsed.description == root.description
        @test length(parsed.children) == 2
        @test isempty(parsed.operations)
        @test_throws ArgumentError run_experiment(root; registry, root=joinpath(directory,"no-run"))
        @test !ispath(joinpath(directory,"no-run"))
        run = run_experiment(root; branch="comparison", registry, root=joinpath(directory,"runs"))
        @test length(run.records) == 1
        @test run.experiment.id == :comparison
        @test !ispath(joinpath(run.directory,"operations","future"))
        # The public attachment path reads through the default registry; use a valid
        # full-horizon task in the independent lifecycle test below.
        @test read_experiment(joinpath(run.directory,"protocol"); registry).id == :comparison
        attached=attach_experiment_run!(protocol,"comparison",run.directory;registry)
        add_experiment_note!(protocol,"comparison";author="Reviewer",text="Paired conformance",runs=(attached,),registry)
        render_experiment(protocol,joinpath(directory,"custom-report");registry)
        grown=ExperimentSpec(:comparison,v"1.0.0";title="Comparison",question="Does it differ?",
            conditions=child.conditions,operations=child.operations,children=(future,))
        write_experiment(joinpath(directory,"grown"),grown;registry)
        attach_experiment_run!(joinpath(directory,"grown"),"",run.directory;registry)
        grown_html=render_experiment(joinpath(directory,"grown"),joinpath(directory,"grown-report");registry)
        @test occursin("matching protocol",read(grown_html,String))
        @test !occursin("historical protocol",read(grown_html,String))
        changed_target=EvaluationTarget(:tiny,target.composition,EvaluationSpec(horizon=2,root_seed=999))
        changed=ExperimentSpec(:comparison,v"1.0.0";title="Comparison",question="Does it differ?",
            conditions=(changed_target,),operations=(ProfilePlan(:profile,changed_target),))
        changed_root=ExperimentSpec(:programme,v"1.0.0";title="Changed",question="?",children=(changed,))
        write_experiment(joinpath(directory,"changed-protocol"),changed_root;registry)
        @test_throws ArgumentError attach_experiment_run!(joinpath(directory,"changed-protocol"),"comparison",run.directory;registry)
        attach_experiment_run!(joinpath(directory,"changed-protocol"),"comparison",run.directory;historical=true,registry)
        historical=render_experiment(joinpath(directory,"changed-protocol"),joinpath(directory,"historical-report");registry)
        @test occursin("historical protocol",read(historical,String))
        manifest = TOML.parsefile(joinpath(protocol,"experiment.toml"))
        manifest["children"][1]["version"] = "9.0.0"
        open(joinpath(protocol,"experiment.toml"),"w") do io
            TOML.print(io, manifest)
        end
        @test_throws ArgumentError read_experiment(protocol; registry)
    end
end

@testset "programme records discussion and export" begin
    target = EvaluationTarget(:tiny,
        CompositionSpec(:tiny,:null_random,:word_sequence_2021;n_nodes=8,
                        task_options=Dict(:sentences=>10)), EvaluationSpec(horizon=40))
    # Null reservoirs have no target channel; use a spike-count diagnostic.
    child = ExperimentSpec(:words,v"1.0.0"; title="Words",question="What happens?",
        conditions=(target,),operations=(ProfilePlan(:words,target;analyses=(:fano_factor,)),))
    root = ExperimentSpec(:programme,v"1.0.0";title="Study",question="Why?",children=(child,))
    mktempdir() do d
        protocol = joinpath(d,"protocol")
        write_experiment(protocol,root)
        run = run_experiment(root;branch="words",root=joinpath(d,"runs"))
        before = BrainlessLab._programme_inventory(run.directory)
        id = attach_experiment_run!(protocol,"words",run.directory)
        @test_throws ArgumentError attach_experiment_run!(protocol,"words",run.directory)
        add_experiment_note!(protocol,"words";author="Researcher",text="<script>alert(1)</script>",runs=(id,))
        @test BrainlessLab._programme_inventory(run.directory) == before
        html = render_experiment(protocol,joinpath(d,"report"))
        @test occursin("&lt;script&gt;", read(html,String))
        @test !occursin("<script>", read(html,String))
        @test isfile(joinpath(d,"report","records",id,"DONE"))
        # An exported bundle is independently usable without its original paths.
        render_experiment(joinpath(d,"report","protocol"),joinpath(d,"second"))
        ledger=TOML.parsefile(joinpath(protocol,"programme.toml"))
        original=read(joinpath(protocol,"programme.toml"),String)
        ledger["runs"][1]["id"]="../escape"
        open(joinpath(protocol,"programme.toml"),"w") do io; TOML.print(io,ledger); end
        @test_throws ArgumentError render_experiment(protocol,joinpath(d,"unsafe"))
        @test !ispath(joinpath(d,"unsafe"))
        write(joinpath(protocol,"programme.toml"),original)
        @test_throws ArgumentError add_experiment_note!(protocol,"words";author="R",text="note",runs=("missing",))
        write(joinpath(run.directory,"DONE"),"changed")
        @test_throws ArgumentError render_experiment(protocol,joinpath(d,"changed"))
        @test !ispath(joinpath(d,"changed"))
    end
end

@testset "incomplete and failed programme attachments" begin
    node=ExperimentSpec(:planned,v"1.0.0";title="Pending",question="?",evidence_state=:planned)
    mktempdir() do d
        protocol=joinpath(d,"programme")
        write_experiment(protocol,node)
        incomplete=joinpath(d,"incomplete")
        write_experiment(joinpath(incomplete,"protocol"),node)
        attach_experiment_run!(protocol,"",incomplete)
        failed=joinpath(d,"failed")
        write_experiment(joinpath(failed,"protocol"),node)
        write(joinpath(failed,"FAILED"),"conformance failure")
        attach_experiment_run!(protocol,"",failed)
        html=read(render_experiment(protocol,joinpath(d,"report")),String)
        @test occursin("· incomplete",html)
        @test occursin("· failed",html)
        mkpath(joinpath(protocol,"discussion"))
        elsewhere=joinpath(d,"must-not-be-written")
        symlink(elsewhere,joinpath(protocol,"discussion","note_0001.md"))
        @test_throws ArgumentError add_experiment_note!(protocol,"";author="R",text="test")
        @test !ispath(elsewhere)
    end
end
