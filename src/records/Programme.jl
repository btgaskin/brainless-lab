"""Records and discussion are an append-only companion to the authored protocol tree."""
function _programme_ledger(directory)
    path = joinpath(directory, "programme.toml")
    data = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}(
        "format" => "brainlesslab-programme", "format_version" => 1,
        "runs" => Any[], "notes" => Any[])
    get(data, "format", "") == "brainlesslab-programme" &&
        get(data, "format_version", 0) == 1 || throw(ArgumentError("invalid programme ledger"))
    for (key, pattern) in (("runs", r"^run_[0-9]+$"), ("notes", r"^note_[0-9]+$"))
        entries = get(data, key, nothing)
        entries isa Vector || throw(ArgumentError("programme ledger requires $(key)"))
        ids = [get(entry, "id", "") for entry in entries]
        all(id -> id isa String && occursin(pattern, id), ids) && length(unique(ids)) == length(ids) ||
            throw(ArgumentError("programme ledger has invalid or duplicate $(key) IDs"))
        required=key=="runs" ? ("branch","path","historical","attached_utc","inventory") :
            ("branch","author","date","file","runs","sha256")
        all(entry -> all(field -> haskey(entry,field),required),entries) ||
            throw(ArgumentError("programme ledger has incomplete $(key) entries"))
    end
    return data
end

function _write_programme_ledger(directory, data)
    path = joinpath(directory, "programme.toml")
    temporary, io = mktemp(directory)
    try
        TOML.print(io, data; sorted=true)
        close(io)
        mv(temporary, path; force=true)
    finally
        isopen(io) && close(io)
        isfile(temporary) && rm(temporary)
    end
    return path
end

_programme_digest(path) = open(io -> bytes2hex(SHA.sha256(io)), path)

function _programme_run(directory; registry=DEFAULT_REGISTRY)
    if isfile(joinpath(directory, "FAILED")) || !isfile(joinpath(directory, "DONE"))
        protocol = read_experiment(joinpath(directory, "protocol"); registry)
        return (experiment=protocol, records=Dict{String,Any}[],
                status=isfile(joinpath(directory, "FAILED")) ? "failed" : "incomplete")
    end
    run = _validate_experiment_run(directory; allow_dirty=true, registry)
    return (experiment=run.experiment, records=run.records, status="complete")
end

function _programme_inventory(directory)
    files = _contribution_files(directory)
    return Dict(replace(path, '\\' => '/') => _programme_digest(joinpath(directory, path))
                for path in files)
end

function _check_programme_inventory(directory, expected)
    _programme_inventory(directory) == expected ||
        throw(ArgumentError("attached experiment run inventory or checksum changed"))
end

# Children are separate execution units. Adding a follow-up question must not
# relabel unchanged results from this node as a different executed protocol.
function _programme_execution_signature(experiment::ExperimentSpec)
    document=experiment_document(experiment)
    delete!(document,"children")
    return (experiment=document,operations=[plan_document(plan) for plan in experiment.operations])
end

"""Attach an immutable experiment run. Dirty development provenance remains visible.

Use `historical=true` to attach a different protocol revision as historical context.
This does not accept a public contribution or change the node's evidence state.
"""
function attach_experiment_run!(directory::AbstractString, branch::AbstractString,
    run_directory::AbstractString; historical::Bool=false, registry=DEFAULT_REGISTRY)
    node = experiment_branch(read_experiment(directory; registry), branch)
    run = _programme_run(run_directory; registry)
    matches = _programme_execution_signature(run.experiment) == _programme_execution_signature(node)
    matches || historical || throw(ArgumentError(
        "run protocol differs from this branch; attach explicitly as historical or select its matching version"))
    data = _programme_ledger(directory)
    relative = replace(relpath(abspath(run_directory), abspath(directory)), '\\' => '/')
    any(entry -> entry["branch"] == branch && entry["path"] == relative, data["runs"]) &&
        throw(ArgumentError("run is already attached to this branch"))
    id = string("run_", lpad(length(data["runs"]) + 1, 4, '0'))
    push!(data["runs"], Dict("id" => id, "branch" => String(branch), "path" => relative,
        "historical" => historical, "attached_utc" => string(now(UTC)),
        "inventory" => _programme_inventory(run_directory)))
    _write_programme_ledger(directory, data)
    return id
end

"""Append a dated authored Markdown note, optionally citing attached run IDs."""
function add_experiment_note!(directory::AbstractString, branch::AbstractString;
    author::AbstractString, text::AbstractString, runs=(), date::AbstractString=string(now(UTC)), registry=DEFAULT_REGISTRY)
    experiment_branch(read_experiment(directory; registry), branch)
    isempty(strip(author)) && throw(ArgumentError("discussion requires an author"))
    isempty(strip(text)) && throw(ArgumentError("discussion requires text"))
    data = _programme_ledger(directory)
    ids = Set(entry["id"] for entry in data["runs"])
    all(id -> String(id) in ids, runs) || throw(ArgumentError("discussion cites an unknown attached run"))
    id = string("note_", lpad(length(data["notes"]) + 1, 4, '0'))
    islink(joinpath(directory,"discussion")) && throw(ArgumentError("discussion directory must not be a symlink"))
    mkpath(joinpath(directory, "discussion"))
    file = "discussion/$(id).md"
    (ispath(joinpath(directory, file)) || islink(joinpath(directory,file))) &&
        throw(ArgumentError("discussion file already exists"))
    write(joinpath(directory, file), text)
    push!(data["notes"], Dict("id" => id, "branch" => String(branch), "author" => String(author),
        "date" => String(date), "file" => file, "runs" => String.(collect(runs)),
        "sha256" => _programme_digest(joinpath(directory, file))))
    _write_programme_ledger(directory, data)
    return id
end

function _programme_nodes(root)
    nodes = Pair{String,ExperimentSpec}[]
    function visit(node, path)
        push!(nodes, path => node)
        for child in node.children
            visit(child, isempty(path) ? String(child.id) : path * "/" * String(child.id))
        end
    end
    visit(root, "")
    return nodes
end

_programme_anchor(path) = isempty(path) ? "programme" : "branch-" * replace(path, '/' => '.')

# Deliberately render Markdown source as escaped, pre-wrapped text. No embedded HTML
# or active links in authored prose are executed. Record links are generated separately.
_programme_prose(text) = "<div class=prose>" * _html_escape(text) * "</div>"

# Presentation is an editorial companion, never part of the executed protocol.
function _programme_presentation(directory, known)
    file = joinpath(directory, "presentation.toml")
    data = isfile(file) ? TOML.parsefile(file) : Dict{String,Any}()
    all(k -> k in ("format_version", "items"), keys(data)) ||
        throw(ArgumentError("unknown presentation field"))
    get(data, "format_version", 1) == 1 || throw(ArgumentError("unsupported presentation version"))
    items = Dict{String,Any}()
    for item in get(data, "items", [])
        all(k -> k in ("branch", "show", "figures"), keys(item)) ||
            throw(ArgumentError("unknown presentation item field"))
        branch = get(item, "branch", nothing)
        branch in known || throw(ArgumentError("presentation references a missing branch"))
        haskey(items, branch) && throw(ArgumentError("duplicate presentation branch"))
        show = get(item, "show", ["description", "hypotheses", "objectives", "discussion"])
        show isa Vector && all(x -> x in ("description", "hypotheses", "objectives", "discussion"), show) ||
            throw(ArgumentError("invalid presentation sections"))
        figures = get(item, "figures", String[])
        figures isa Vector && all(x -> x isa String, figures) && length(unique(figures)) == length(figures) ||
            throw(ArgumentError("presentation figures must be unique string references"))
        items[branch] = (show=show, figures=figures)
    end
    return items
end

_programme_display(items, path) = get(items, path,
    (show=["description", "hypotheses", "objectives", "discussion"], figures=String[]))

# Only our generated figures are selected here; authored HTML is never interpreted.
function _programme_figure_catalogue(html)
    return Dict(String(m.captures[1]) => String(m.match) for m in
        eachmatch(r"<figure><figcaption>(.*?)</figcaption>.*?</figure>"s, html))
end

function _programme_chart(title, xlabel, series; logarithmic=false)
    points = [(x,y) for (_,values) in series for (x,y) in values if isfinite(x) && isfinite(y) && (!logarithmic || x>0)]
    isempty(points) && return ""
    transform(x)=logarithmic ? log10(x) : x
    xmin,xmax=extrema(transform(x) for (x,_) in points)
    ymin,ymax=extrema(y for (_,y) in points)
    xmin==xmax && (xmin-=0.5; xmax+=0.5)
    padding=max((ymax-ymin)*0.08,0.01); ymin-=padding; ymax+=padding
    px(x)=65+600*(transform(x)-xmin)/(xmax-xmin)
    py(y)=240-210*(y-ymin)/(ymax-ymin)
    io=IOBuffer()
    print(io,"<figure><figcaption>",_html_escape(title),"</figcaption><svg role='img' aria-label='",_html_escape(title),
        "' viewBox='0 0 700 300' width='100%'><title>",_html_escape(title),"</title><path d='M65 25V240H670' fill='none' stroke='#69776c'/>")
    for t in 0:4
        y=ymin+(ymax-ymin)*t/4
        print(io,"<text x='59' y='",py(y)+4,"' text-anchor='end' font-size='11'>",round(y;sigdigits=3),"</text>")
    end
    xs=sort!(unique(first.(points)))
    length(xs)>8 && (xs=xs[unique(round.(Int,range(1,length(xs);length=6)))])
    for x in xs
        print(io,"<text x='",px(x),"' y='260' text-anchor='middle' font-size='11'>",round(x;sigdigits=3),"</text>")
    end
    colours=("#14675f","#b35138","#64569b","#917211","#317cab")
    legend=String[]
    for (i,(label,values)) in enumerate(series)
        colour=colours[mod1(i,length(colours))]
        valid=sort([(x,y) for (x,y) in values if isfinite(x) && isfinite(y) && (!logarithmic || x>0)];by=first)
        print(io,"<polyline fill='none' stroke='",colour,"' stroke-width='2' points='",join(("$(px(x)),$(py(y))" for (x,y) in valid)," "),"'/>")
        for (x,y) in valid
            print(io,"<circle cx='",px(x),"' cy='",py(y),"' r='3' fill='",colour,"'><title>",_html_escape(label),": ",x,", ",y,"</title></circle>")
        end
        push!(legend,"<span style='color:$(colour)'>● $(_html_escape(label))</span>")
    end
    print(io,"<text x='360' y='289' text-anchor='middle' font-size='12'>",_html_escape(xlabel),"</text></svg><div>",join(legend," · "),"</div></figure>")
    return String(take!(io))
end

_programme_figures(directory, plan::AbstractOperationPlan) = ""
_programme_number(row, key)=something(tryparse(Float64,get(row,key,"")),NaN)

function _programme_figures(directory, plan::BenchmarkPlan)
    targets=Dict(t.id=>t for case in plan.cases for t in case.conditions)
    all(t->t.composition.node===:falandays,values(targets)) || return ""
    all(t->get(t.composition.parameters,:learn_on,true),values(targets)) || return ""
    length(unique(t.composition.task for t in values(targets)))==1 || return ""
    all(t->haskey(t.composition.parameters,:recurrent_init_scale),values(targets)) || return ""
    # Draw a scale curve only when all remaining settings agree. Other benchmarks
    # keep their ordinary task/case report rather than silently pooling conditions.
    signatures=[begin
        doc=_target_document(t)
        delete!(doc,"id"); delete!(doc["composition"],"id")
        for key in ("recurrent_init_scale","lrate_wmat","lrate_targ")
            pop!(doc["composition"]["parameters"],key,nothing)
        end
        doc
    end for t in values(targets)]
    all(==(first(signatures)),signatures) || return ""
    for key in (:lrate_wmat,:lrate_targ)
        rates=unique(get(t.composition.parameters,key,:default) for t in values(targets))
        length(filter(!=(0),rates))<=1 || return ""
    end
    baselines=[begin
        p=targets[case.baseline].composition.parameters
        (get(p,:lrate_wmat,:default),get(p,:lrate_targ,:default))
    end for case in plan.cases if case.baseline!==nothing]
    length(unique(baselines))<=1 || return ""
    statistics=_read_record_csv(joinpath(directory,"summary","statistics.csv"))
    contrasts=_read_record_csv(joinpath(directory,"summary","contrasts.csv"))
    io=IOBuffer()
    for (title,rows,key) in (("Raw task score",statistics,:raw_mean),
        ("Anchor-relative score",statistics,:normalized_mean),
        ("Paired raw difference from declared baseline",contrasts,:raw_difference),
        ("Paired anchor-relative difference",contrasts,:normalized_difference))
        groups=Dict{String,Vector{Tuple{Float64,Float64}}}()
        for row in rows
            t=targets[Symbol(row.condition)]; p=t.composition.parameters
            label="weights $(get(p,:lrate_wmat,1)==0 ? "off" : "on"), targets $(get(p,:lrate_targ,1)==0 ? "off" : "on")"
            push!(get!(groups,label,Tuple{Float64,Float64}[]),
                (Float64(p[:recurrent_init_scale]),_programme_number(row,key)))
        end
        print(io,_programme_chart(title,"Recurrent initialisation scale (log axis)",sort!(collect(groups);by=first);logarithmic=true))
    end
    print(io,"<p class=meta>Points show recorded means. Paired-block intervals, independent counts and normalisation limits are in the linked operation report and CSV tables. Missing values are not plotted.</p>")
    return String(take!(io))
end

function _programme_figures(directory, plan::ProfilePlan)
    path=joinpath(directory,"data","analysis_series.csv")
    isfile(path) || return ""
    rows=_read_record_csv(path)
    figures=String[]
    for statistic in ("spike_count","mean_target_error","correlation")
        groups=Dict{String,Vector{Tuple{Float64,Float64}}}()
        for row in rows
            row.analysis=="word_sequence_diagnostics" && row.statistic==statistic || continue
            row.series=="completion_context_matrix" && continue
            push!(get!(groups,row.series,Tuple{Float64,Float64}[]),
                (_programme_number(row,:coordinate_value),_programme_number(row,:mean)))
        end
        push!(figures,_programme_chart(replace(statistic,'_'=>' '),
            statistic=="correlation" ? "Completion tick" : "Tick from raw start",sort!(collect(groups);by=first)))
    end
    return join(figures)
end

"""Generate an offline HTML report and copy attached records without executing operations.

The destination must be new. The export contains an independent copy of the authored
tree, discussion ledger and every attached run, with a checksummed export inventory.
"""
function render_experiment(directory::AbstractString, destination::AbstractString; registry=DEFAULT_REGISTRY)
    ispath(destination) && throw(ArgumentError("report destination already exists"))
    root = read_experiment(directory; registry)
    data = _programme_ledger(directory)
    nodes = _programme_nodes(root)
    known = Set(first.(nodes))
    presentation = _programme_presentation(directory, known)
    figures = Dict{String,String}()
    figure_branches = Dict{String,String}()
    figure_status = Dict{String,String}()
    for entry in data["runs"]
        entry["branch"] in known || throw(ArgumentError("run references a missing branch"))
        isabspath(entry["path"]) && throw(ArgumentError("programme run paths must be relative"))
        path = normpath(joinpath(directory, entry["path"]))
        _check_programme_inventory(path, entry["inventory"])
        run = _programme_run(path; registry)
        node = experiment_branch(root, entry["branch"])
        historical = entry["historical"] || _programme_execution_signature(run.experiment) != _programme_execution_signature(node)
        for record in run.records
            operation = joinpath(path, record["path"])
            plan = read_plan(joinpath(operation, "request.toml"); registry)
            for (title, html) in _programme_figure_catalogue(_programme_figures(operation, plan))
                key = entry["id"] * "/" * string(plan.id) * "/" * title
                figures[key] = html
                figure_branches[key] = entry["branch"]
                figure_status[key] = historical ? "Historical protocol" : "Matching protocol"
            end
        end
    end
    for (branch, item) in presentation, ref in item.figures
        key = _html_escape(ref)
        get(figure_branches, key, nothing) == branch ||
            throw(ArgumentError("selected figure is missing or belongs to another branch: $(ref)"))
    end
    for note in data["notes"]
        note["branch"] in known || throw(ArgumentError("note references a missing branch"))
        path = _contribution_child(directory, note["file"], "discussion file")
        note["file"] == "discussion/$(note["id"]).md" || throw(ArgumentError("invalid discussion path"))
        (islink(joinpath(directory,"discussion")) || islink(path)) && throw(ArgumentError("discussion paths must not be symlinks"))
        _programme_digest(path) == note["sha256"] || throw(ArgumentError("discussion entry changed"))
        all(id -> any(run -> run["id"] == id, data["runs"]), note["runs"]) ||
            throw(ArgumentError("note references a missing run"))
    end
    mkpath(destination)
    write_experiment(joinpath(destination, "protocol"), root; registry)
    isfile(joinpath(directory, "presentation.toml")) &&
        cp(joinpath(directory, "presentation.toml"), joinpath(destination, "protocol", "presentation.toml"))
    exported = deepcopy(data)
    for (entry, output) in zip(data["runs"], exported["runs"])
        target = joinpath(destination, "records", entry["id"])
        mkpath(dirname(target))
        cp(normpath(joinpath(directory, entry["path"])), target)
        _check_programme_inventory(target, entry["inventory"])
        output["path"] = "../records/" * entry["id"]
    end
    for note in data["notes"]
        target = joinpath(destination, "protocol", note["file"])
        mkpath(dirname(target))
        cp(joinpath(directory, note["file"]), target)
    end
    _write_programme_ledger(joinpath(destination, "protocol"), exported)
    function tree(node, path)
        link = "<a href='#$(_programme_anchor(path))'>$(_html_escape(node.title))</a>"
        isempty(node.children) && return "<li>$(link)</li>"
        children = join(tree(child, isempty(path) ? String(child.id) : path * "/" * String(child.id))
                        for child in node.children)
        return "<li><details open><summary>$(link)</summary><ul>$(children)</ul></details></li>"
    end
    body = IOBuffer()
    for (path, node) in nodes
        display = _programme_display(presentation, path)
        runs = filter(entry -> entry["branch"] == path, data["runs"])
        status = isempty(runs) ? (isempty(node.operations) ? "Question · no executable protocol" : "Protocol · no attached runs") :
            "$(length(runs)) attached run(s) · historical status shown below"
        print(body, "<section id='$(_programme_anchor(path))'><p class=meta>",
            _html_escape(isempty(path) ? String(root.id) : path), " · v", node.version,
            " · evidence: ", node.evidence_state, "</p><h2>", _html_escape(node.title), "</h2><p class=status>",
            status, "</p>", _programme_prose(node.question))
        "description" in display.show && print(body, _programme_prose(node.description))
        for (title, items) in (("Objectives", node.objectives), ("Hypotheses", node.hypotheses))
            lowercase(title) in display.show || continue
            isempty(items) || print(body, "<h3>", title, "</h3><ul>",
                join("<li>" * _html_escape(item) * "</li>" for item in items), "</ul>")
        end
        for ref in display.figures
            run_id = first(split(ref, '/'))
            print(body, figures[_html_escape(ref)], "<p class=meta>Selected from <a href='#",run_id,"'>",
                _html_escape(ref),"</a> · ",figure_status[_html_escape(ref)],
                ". Recorded means; uncertainty and independent counts are in the operation report.</p>")
        end
        isempty(node.limitations) || print(body, "<p class=meta>",
            join(_html_escape.(node.limitations), " "), "</p>")
        print(body, "<details class=records><summary>Methods and records · ",length(runs)," attached run(s)</summary>")
        isempty(node.operations) || print(body, "<details><summary>Declared operations (",length(node.operations),")</summary><ul>",
            join("<li>" * _html_escape(plan.id) * " · " * String(operation_kind(plan)) * "</li>" for plan in node.operations), "</ul></details>")
        for entry in runs
            run_path = joinpath(destination, "records", entry["id"])
            run = _programme_run(run_path; registry)
            historical = entry["historical"] || _programme_execution_signature(run.experiment) != _programme_execution_signature(node)
            print(body, "<article id='", entry["id"], "'><h3>", entry["id"],
                historical ? " · historical protocol" : " · matching protocol", " · ", run.status, "</h3>")
            print(body,"<p><a href='records/",entry["id"],"/protocol/experiment.toml'>Executed protocol snapshot</a></p>")
            for record in run.records
                relative = "records/" * entry["id"] * "/" * record["path"]
                m = record["manifest"]
                print(body, "<p><a href='", _html_escape(relative), "/report/index.html'>",
                    _html_escape(m["id"]), "</a> · source ", _html_escape(m["git_sha"]),
                    " · ", _html_escape(m["git_state"]), "</p><p><a href='", _html_escape(relative),
                    "/data/trials.csv'>Trial table</a> · <a href='", _html_escape(relative),
                    "/resolved.toml'>Resolved settings</a> · <a href='", _html_escape(relative), "/seeds.csv'>Seeds</a></p>")
                plan = read_plan(joinpath(destination, relative, "request.toml"); registry)
                prefix = entry["id"] * "/" * string(plan.id) * "/"
                print(body,"<details><summary>Diagnostic figures and selection references</summary>")
                for key in sort!(filter(k -> startswith(k,prefix), collect(keys(figures))))
                    print(body, figures[key], "<p class=meta>Figure reference: <code>",key,"</code></p>")
                end
                print(body,"</details>")
            end
            print(body, "</article>")
        end
        print(body, "</details>")
        notes = filter(note -> note["branch"] == path, data["notes"])
        "discussion" in display.show || (notes = [])
        isempty(notes) || print(body, "<h3>Discussion and decisions</h3>")
        for note in notes
            print(body, "<article><p class=meta>", _html_escape(note["date"]), " · ", _html_escape(note["author"]),
                "</p>", _programme_prose(read(joinpath(directory, note["file"]), String)),
                "<p>", join("<a href='#" * id * "'>" * id * "</a>" for id in note["runs"]), "</p></article>")
        end
        print(body, "</section>")
    end
    html = """<!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><title>$(_html_escape(root.title)) · BrainlessLab</title>
    <style>html{overflow-wrap:anywhere}figure{margin:1.5rem 0}svg{display:block;max-width:100%}.records{margin:1.5rem 0;padding:1rem;border:1px solid #ccc9bb;border-radius:4px}.records>summary{font-weight:600}figcaption{font-weight:600}.prose:empty{display:none}@media(max-width:600px){svg text{font-size:22px}}</style>
    <style>body{margin:0;background:#f7f5ef;color:#22322f;font:16px/1.65 system-ui,sans-serif}header{padding:3rem 5vw;border-bottom:1px solid #ccc9bb}h1,h2{font-family:Georgia,serif;font-weight:400;line-height:1.2}h1{font-size:clamp(2rem,4vw,3.5rem);max-width:1000px}h2{font-size:2rem}a{color:#14675f;text-underline-offset:3px}nav{padding:2rem;position:sticky;top:0;align-self:start;max-height:95vh;overflow:auto}nav ul{padding-left:1.1rem}nav li{margin:.7rem 0}.layout{display:grid;grid-template-columns:minmax(260px,340px) minmax(0,850px);max-width:1280px;margin:auto}main{padding:0 3rem 4rem}section{padding:2.5rem 0;border-bottom:1px solid #ccc9bb;scroll-margin-top:1rem}.meta,.status{font-size:.8rem;color:#52665e}.prose{white-space:pre-wrap;overflow-wrap:anywhere;margin:1rem 0}article{border-left:2px solid #9eb5aa;padding-left:1.2rem;margin:1.5rem 0}summary{cursor:pointer}:focus-visible{outline:3px solid #d49435;outline-offset:3px}@media(max-width:800px){.layout{display:block}nav{position:static;max-height:none}main{padding:0 5vw}}@media print{nav{display:none}.layout{display:block}body{background:white}section{break-inside:avoid}a{color:inherit}}</style></head>
    <body><header><p>BrainlessLab · Experimental programme</p><h1>$(_html_escape(root.title))</h1>
    <p>A growing record of questions, methods and evidence. Completion does not imply confirmation.</p></header>
    <div class=layout><nav aria-label="Programme tree"><ul>$(tree(root, ""))</ul></nav><main>$(String(take!(body)))</main></div></body></html>"""
    write(joinpath(destination, "index.html"), html)
    inventory = _programme_inventory(destination)
    open(joinpath(destination, "export.toml"), "w") do io
        TOML.print(io, Dict("format" => "brainlesslab-programme-export", "format_version" => 1,
                           "artifact_sha256" => inventory); sorted=true)
    end
    return joinpath(destination, "index.html")
end
