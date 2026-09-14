using BrainlessLab, Test, Random

@testset "word grammar and paired completion" begin
    a = BrainlessLab.WordSequenceEnv(seed=72,sentences=20)
    b = BrainlessLab.WordSequenceEnv(seed=72,sentences=20,completion_cues=1)
    @test a.stream == b.stream[1:80]
    @test b.visible[81:84] == [true,false,false,false]
    @test all(a.stream[4:4:end] .== 7)
    @test all(a.stream[1:4:end] .<= 2)
    @test all(i -> a.stream[i] in (3,4), 2:4:80)
    @test all(i -> a.stream[i] in (5,6), 3:4:80)
    @test_throws ArgumentError BrainlessLab.WordSequenceEnv(sentences=0)
end

@testset "word diagnostics retain original error and context" begin
    sim=simulate(:word_sequence_2021;node=:falandays,n_nodes=16,ticks=44,window=44,
        task_kwargs=(sentences=10,completion_cues=1),record=(:spikes,:errors),seed=711)
    @test task_outcome(sim) === nothing
    result=BrainlessLab.word_sequence_diagnostics(sim)
    responses=only(filter(s->s.id==:responses,result.series))
    @test length(responses.coordinates)==44
    @test length(filter(s->startswith(String(s.id),"raster_node_"),result.series))==16
    matrix=only(filter(s->s.id==:completion_context_matrix,result.series))
    @test length(matrix.coordinates)==136
    @test all(x->isnan(x) || -1.00000001 <= x <= 1.00000001,matrix.values.correlation)
end

@testset "2021 recurrence and adaptation from explicit initial state" begin
    random = MersenneTwister(211)
    n = 16
    mask = rand(random,n,n) .< 0.25
    for i in 1:n; mask[i,i]=false; end
    sensory = 5.0 .* (rand(random,5,n) .< 0.3)
    weights = randn(random,n,n) .* mask
    for scale in (0.01,1.0), learn in (false,true)
        params = FalandaysParams(leak=0.25,lrate_wmat=0.1,lrate_targ=0.01,learn_on=learn)
        r = FalandaysReservoir(;params,recurrent_mask=mask,input_wmat=sensory,
            output_mask=zeros(n,1),wmat0=scale .* weights,rectify=true)
        w = scale .* weights
        acts=zeros(n); spikes=zeros(n); targets=ones(n)
        for tick in 1:60
            input = zeros(5); input[mod1(tick,5)]=1
            previous = copy(spikes)
            # Source-equation reference: retention is .75, rectification follows reset.
            for j in 1:n
                acts[j] = 0.75acts[j] + sum(input[k]*sensory[k,j] for k in 1:5) +
                          sum(previous[k]*w[k,j] for k in 1:n)
                spikes[j] = acts[j] >= 2targets[j] ? 1.0 : 0.0
                acts[j] = max(0.0,acts[j] - spikes[j]*2targets[j])
            end
            errors = acts .- targets
            if learn
                for j in 1:n
                    active = count(k -> mask[k,j] && previous[k]>0,1:n)
                    if active>0
                        for k in 1:n
                            mask[k,j] && previous[k]>0 && (w[k,j] -= 0.1errors[j]/active)
                        end
                    end
                end
                targets .= max.(1.0,targets .+ 0.01errors)
            end
            step!(r,input)
            @test r.acts ≈ acts atol=1e-10
            @test r.spikes == spikes
            @test r.targets ≈ targets atol=1e-10
            @test r.wmat ≈ w atol=1e-10
        end
    end
end
