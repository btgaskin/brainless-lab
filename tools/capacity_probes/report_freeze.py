# /// script
# requires-python = ">=3.11"
# dependencies = ["matplotlib==3.10.0"]
# ///
"""Render native freeze curves from immutable standard benchmark records.

No simulation or parameter selection is executed by this analysis. Run with:
uv run tools/capacity_probes/report_freeze.py RUNS_DIRECTORY NEW_REPORT_DIRECTORY
"""
import argparse
import csv
import copy
import hashlib
import html
import json
import math
from pathlib import Path
import shutil
import statistics
import sys
import tomllib
import zipfile


def read_csv(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))


def estimate(values):
    values = list(values)
    mean = statistics.mean(values)
    sem = statistics.stdev(values) / math.sqrt(len(values)) if len(values)>1 else None
    return mean, sem


def adjacent_slopes(points):
    """Pair block means, then divide by actual tick spacing. Preserve ties and signs."""
    result = []
    ordered = sorted(points)
    for left, right in zip(ordered, ordered[1:]):
        if set(points[left]) != set(points[right]):
            raise ValueError('unmatched independent blocks')
        values = [(points[right][b]-points[left][b])/(right-left) for b in sorted(points[left])]
        mean, sem = estimate(values)
        result.append(dict(left=left, right=right, midpoint=(left+right)/2,
                           slope=mean, sem=sem, blocks=len(values)))
    maximum = max((abs(row['slope']) for row in result), default=0.0)
    for row in result:
        row['steepest'] = maximum>0 and math.isclose(abs(row['slope']), maximum, rel_tol=1e-9, abs_tol=1e-15)
    return result


def load_record(directory):
    if not (directory/'DONE').is_file() or (directory/'FAILED').exists():
        raise ValueError(f'incomplete record: {directory}')
    manifest = tomllib.loads((directory/'record.toml').read_text())
    required = {'request.toml','resolved.toml','data/trials.csv','summary/statistics.csv','seeds.csv'}
    if not required.issubset(manifest['artifact_sha256']):
        raise ValueError('consumed inputs must be inventoried')
    for name, digest in manifest['artifact_sha256'].items():
        path = (directory/name).resolve()
        if not path.is_relative_to(directory.resolve()):
            raise ValueError('invalid artifact path')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise ValueError(f'checksum mismatch: {name}')
    plan = tomllib.loads((directory/'request.toml').read_text())
    run = directory.parent.parent
    if not (run/'DONE').is_file() or (run/'FAILED').exists():
        raise ValueError('incomplete parent experiment run')
    execution = tomllib.loads((run/'experiment-run.toml').read_text())
    protocol = tomllib.loads((run/'protocol/experiment.toml').read_text())
    if execution['protocol']!='protocol/experiment.toml' or execution['experiment']!=protocol['id'] or execution['experiment_version']!=protocol['version']:
        raise ValueError('parent experiment identity mismatch')
    if len(execution['operation_records'])!=len(protocol['operations']) or len(set(execution['operation_records']))!=len(protocol['operations']):
        raise ValueError('parent operation inventory mismatch')
    own_path = directory.relative_to(run).as_posix()
    position = execution['operation_records'].index(own_path)
    operation = protocol['operations'][position]
    protocol_plan = (run/'protocol/plans'/operation['plan']).resolve()
    if not protocol_plan.is_relative_to((run/'protocol/plans').resolve()) or tomllib.loads(protocol_plan.read_text())!=plan:
        raise ValueError('executed protocol does not match recorded request')
    if plan['operation']!='benchmark':
        raise ValueError('freeze curves require benchmark records')
    targets = {t['id']:t for t in plan['targets']}
    resolved = {t['id']:t for t in tomllib.loads((directory/'resolved.toml').read_text())['targets']}
    seed_rows = read_csv(directory/'seeds.csv')
    trials = read_csv(directory/'data/trials.csv')
    summaries = read_csv(directory/'summary/statistics.csv')
    seen = set()
    for r in trials:
        identity = (r['case'], r['condition'], r['block'], r['trial'])
        if identity in seen:
            raise ValueError('duplicate trial')
        seen.add(identity)
        t = targets[r['condition']]
        if int(r['executed_scored_ticks'])!=t['evaluation']['horizon']-t['evaluation']['warmup']:
            raise ValueError('incomplete scored window')
        if not math.isfinite(float(r['raw_score'])):
            raise ValueError('non-finite outcome')
    output = []
    for case in plan['benchmark']['cases']:
        members = {name:targets[name] for name in case['conditions']}
        sample = members[case['baseline']]
        canonical = copy.deepcopy(sample)
        canonical.pop('id'); canonical.pop('interventions',None); canonical['composition'].pop('id')
        canonical_resolved = {k:v for k,v in resolved[sample['id']].items() if k not in ('id','composition_id','interventions')}
        parameters = canonical_resolved['parameters']
        if not parameters['learn_on'] or parameters['lrate_wmat']<=0 or parameters['lrate_targ']<=0:
            raise ValueError('baseline adaptation must be active')
        task = sample['composition']['task']
        if task not in ('delayed_cue','recall_interference','delayed_xor','evidence_accumulation','context_integration','temporal_order','reversal_adaptation'):
            raise ValueError('native capacity task required')
        e = sample['evaluation']
        if e['warmup']!=0 or e['reset']!='full' or e['construction_scope']!='block':
            raise ValueError('capacity freeze curves require full resets, block wiring and zero warmup')
        opts = sample['composition']['task_options']
        if task=='reversal_adaptation' and opts['reversal_range']!=[48,48]:
            raise ValueError('this report requires the declared fixed reversal at round 48')
        case_rows = [r for r in trials if r['case']==case['id']]
        expected = {(str(b),str(t)) for b in range(1,sample['evaluation']['blocks']+1)
                    for t in range(1,sample['evaluation']['trials_per_block']+1)}
        paired = {}
        block_means = {}
        seed_reference = None
        for name, target in members.items():
            settings = copy.deepcopy(target)
            settings.pop('id'); settings.pop('interventions',None); settings['composition'].pop('id')
            resolved_settings = {k:v for k,v in resolved[name].items() if k not in ('id','composition_id','interventions')}
            if settings!=canonical or resolved_settings!=canonical_resolved:
                raise ValueError('conditions differ beyond the freeze schedule')
            seeds = sorted(tuple(sorted((k,v) for k,v in r.items() if k!='condition'))
                for r in seed_rows if r['case']==case['id'] and r['condition']==name)
            if not seeds or (seed_reference is not None and seeds!=seed_reference):
                raise ValueError('full seed ledgers are not paired')
            seed_reference = seeds
            rows = [r for r in case_rows if r['condition']==name]
            if {(r['block'],r['trial']) for r in rows}!=expected:
                raise ValueError('missing trial or mismatched replication')
            for r in rows:
                expected_key = 'adaptation_accuracy' if task=='reversal_adaptation' else 'recall_accuracy' if task=='delayed_cue' else 'probe_accuracy'
                if r['score_key']!=expected_key or not 0<=float(r['raw_score'])<=1:
                    raise ValueError('unexpected native outcome')
                key = (r['block'],r['trial'])
                seeds = (r['topology_seed'],r['world_seed'])
                if paired.setdefault(key,seeds)!=seeds:
                    raise ValueError('unpaired seeds')
            block_means[name] = {b:statistics.mean(float(r['raw_score']) for r in rows if r['block']==b)
                                 for b in {r['block'] for r in rows}}
        baseline = block_means[case['baseline']]
        curves = {}
        for name, target in members.items():
            schedule = target.get('interventions',[])
            if name==case['baseline']:
                if schedule:
                    raise ValueError('baseline must be continuous adaptation')
                continue
            if len(schedule)!=1 or schedule[0]['verb'] not in ('freeze_weights','freeze_plasticity'):
                raise ValueError('expected one supported freeze intervention')
            n = schedule[0]['tick']-1
            points = curves.setdefault(schedule[0]['verb'],{})
            if n in points:
                raise ValueError('duplicate cutoff')
            points[n] = block_means[name]
        if not curves:
            raise ValueError('no freeze conditions')
        output.append(dict(case=case['id'], task=sample['composition']['task'],
            title=protocol['title'],
            cutoff_resolution=sum(opts[k] for k in ('cue_ticks','response_ticks','feedback_ticks')) if task=='reversal_adaptation' else 1,
            scale=sample['composition']['parameters']['recurrent_init_scale'],
            baseline=baseline, curves=curves, score_key=case_rows[0]['score_key'],
            evaluation=sample['evaluation'],
            normalized_status=sorted({r['normalization_status'] for r in case_rows}),
            summaries=[s for s in summaries if s['case']==case['id']],
            slopes={m:adjacent_slopes(p) for m,p in curves.items()}))
    return manifest, output


def report(source, destination, programme=None):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    archive = destination.with_name(destination.name+'.zip')
    if destination.exists() or archive.exists():
        raise ValueError('report destination must be new')
    records = sorted(source.glob('*/operations/*/record.toml'))
    if not records:
        raise ValueError('no standard experiment operation records found')
    # Validate all evidence before writing any presentation output.
    loaded = [(p.parent,*load_record(p.parent)) for p in records]
    if programme is not None:
        inventory=tomllib.loads((programme/'export.toml').read_text())['artifact_sha256']
        for name,digest in inventory.items():
            path=(programme/name).resolve()
            if not path.is_relative_to(programme.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
                raise ValueError('programme export checksum mismatch')
    destination.mkdir(parents=True)
    if programme is not None:
        shutil.copytree(programme,destination/'programme')
    sections, links, analyses = [], [], []
    for index,(directory, manifest, cases) in enumerate(loaded):
        relative = Path('records')/str(index+1)
        shutil.copytree(directory,destination/relative)
        run = directory.parent.parent
        shutil.copytree(run/'protocol', destination/'protocols'/str(index+1))
        for case in cases:
            key = f'curve-{index+1}-{case["case"]}'
            title = f'{case["title"]} · recurrent scale {case["scale"]}'
            links.append(f'<li><a href="#{key}">{html.escape(title)}</a></li>')
            fig, axes = plt.subplots(2,1,figsize=(6,7),sharex=True,layout='constrained')
            baseline, baseline_sem = estimate(case['baseline'].values())
            axes[0].axhline(baseline,color='#555555',linestyle='--',label='Continuous adaptation')
            if baseline_sem is not None:
                axes[0].axhspan(baseline-baseline_sem,baseline+baseline_sem,color='#555555',alpha=.10)
            axes[0].axhline(.5,color='#aaaaaa',linestyle=':',label='Chance accuracy')
            findings = []
            for mechanism, points in case['curves'].items():
                label = 'Freeze weights' if mechanism=='freeze_weights' else 'Freeze all plasticity'
                xs = sorted(points)
                means, sems = zip(*(estimate(points[x].values()) for x in xs))
                axes[0].errorbar(xs,means,yerr=sems if all(s is not None for s in sems) else None,
                                 marker='o',capsize=3,label=label)
                slopes = case['slopes'][mechanism]
                axes[1].errorbar([r['midpoint'] for r in slopes],[r['slope'] for r in slopes],
                    yerr=[r['sem'] for r in slopes] if all(r['sem'] is not None for r in slopes) else None,
                    xerr=[(r['right']-r['left'])/2 for r in slopes],
                    marker='o',capsize=3,label=label)
                selected = [r for r in slopes if r['steepest']]
                if not slopes:
                    findings.append(f'{label}: insufficient cutoffs to estimate a slope.')
                elif not selected:
                    findings.append(f'{label}: flat sampled mean curve; no non-zero steepest interval.')
                for row in selected:
                    step = case['cutoff_resolution']
                    candidate = step*round(row['midpoint']/step)
                    suggestion = f'Candidate next cutoff: {candidate} adaptive ticks.' if row['left']<candidate<row['right'] else 'No interior cutoff at this timing resolution.'
                    findings.append(f'{label}: steepest observed interval {row["left"]}–{row["right"]} ticks; slope {row["slope"]:+.5g} raw score/tick. {suggestion}')
            axes[0].set_ylabel(case['score_key']+' (raw)',fontsize=13)
            axes[0].set_ylim(-.08,1.08)
            axes[0].legend(fontsize=10)
            axes[1].axhline(0,color='#aaaaaa',linewidth=.7)
            axes[1].set_ylabel('Adjacent paired slope\n(raw score / adaptive tick)',fontsize=13)
            axes[1].set_xlabel('Adaptive ticks before freezing',fontsize=13)
            for ax in axes:
                ax.grid(alpha=.15)
                ax.tick_params(labelsize=12)
                ax.spines[['top','right']].set_visible(False)
            figure = key+'.svg'
            fig.savefig(destination/figure)
            plt.close(fig)
            rows = ''.join('<tr>'+''.join(f'<td>{html.escape(str(s[k]))}</td>' for k in
                ('condition','raw_mean','normalized_mean','normalized_censoring','blocks'))+'</tr>' for s in case['summaries'])
            e = case['evaluation']
            sections.append(f'<section id="{key}"><h2>{html.escape(title)}</h2><p>Freeze after n completed adaptive ticks. '
                f'{e["blocks"]} independent wiring blocks; {e["trials_per_block"]} episodes per block; '
                f'ticks 1–{e["horizon"]}, full reset and no discarded warm-up.</p>'
                f'<img src="{figure}" alt="Raw freeze-time curve and adjacent paired slopes">'
                '<p>Vertical error bars show ±1 standard error across independent blocks, not confidence bands. '
                'Horizontal slope bars span the two sampled cutoffs; they are not timing uncertainty. '
                'Slopes pair the same blocks and use actual tick spacing. Continuous adaptation is a reference, not a derivative endpoint.</p>'
                + ''.join('<p>'+html.escape(f)+'</p>' for f in findings)+
                '<p>A steep interval is an exploratory refinement suggestion, not a confirmed knee. '
                'A chance-level curve does not establish useful task performance.</p>'
                '<details><summary>Methods, normalised scores and complete records</summary>'
                f'<p>Outcome: {case["score_key"]}; normalisation: {html.escape(str(case["normalized_status"]))}. '
                f'Source {manifest["git_sha"]}, {manifest["git_state"]}; Julia {manifest["julia_version"]}.</p>'
                f'<p><a href="{relative.as_posix()}/report/index.html">Operation report and all trials</a> · '
                f'<a href="protocols/{index+1}/experiment.toml">Executed experiment</a></p>'
                '<div class="table"><table><tr><th>Condition</th><th>Raw mean</th><th>Normalised mean</th><th>Clipping</th><th>Blocks</th></tr>'
                + rows+'</table></div></details></section>')
            analyses.append(dict(title=title, source_record=relative.as_posix(), source_sha=manifest['git_sha'],
                slopes=case['slopes'], findings=findings))
    document = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
    document += '<title>Capacity probes: freeze-time curves</title><style>body{margin:0;background:#f7f5ef;color:#22322f;font:16px/1.65 system-ui}header,main{max-width:960px;margin:auto;padding:2rem}h1,h2{font-family:Georgia,serif;font-weight:400}a{color:#14675f}section{border-top:1px solid #ccc9bb;padding:2rem 0}img{width:100%;height:auto}details{padding:1rem;border:1px solid #ccc9bb}.table{overflow:auto}td,th{padding:.4rem;text-align:left}p{overflow-wrap:anywhere}</style>'
    document += '<header><h1>When does plasticity matter?</h1><p>Exploratory native capacity-probe curves. '
    document += 'Each episode starts afresh; this measures within-episode timing, not accumulated learning. '
    document += 'Reversal uses a declared fixed reversal at round 48 and the native first-16-post-reversal-round outcome. '
    document += 'Other probes score their final response. Native accuracy and decoded information are different questions.</p>'
    if programme is not None:
        document += '<p><a href="programme/index.html">Full programme tree, earlier results and discussion</a></p>'
    document += '<nav><ul>'+''.join(links)+'</ul></nav></header><main>'
    document += ''.join(sections)+'</main></html>'
    (destination/'index.html').write_text(document)
    (destination/'analysis.json').write_text(json.dumps(analyses,indent=2)+'\n')
    (destination/'analysis-environment.json').write_text(json.dumps(
        dict(python=sys.version, matplotlib=matplotlib.__version__),indent=2)+'\n')
    shutil.copy2(__file__,destination/'report_freeze.py')
    inventory = {str(p.relative_to(destination)):hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in destination.rglob('*') if p.is_file()}
    (destination/'checksums.json').write_text(json.dumps(inventory,indent=2)+'\n')
    with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_DEFLATED) as z:
        for p in sorted(destination.rglob('*')):
            if p.is_file():
                z.write(p,Path(destination.name)/p.relative_to(destination))
    return destination/'index.html'


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--programme-export',type=Path)
    args = parser.parse_args()
    print(report(args.runs,args.output,args.programme_export))
