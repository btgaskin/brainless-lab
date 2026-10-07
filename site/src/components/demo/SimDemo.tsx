import { useEffect, useState } from 'react';
import { ArrowCounterClockwise, Pause, Play, SkipForward } from '@phosphor-icons/react';
import { TaskCanvas } from './TaskCanvas';
import { nextFrame, parseIndex, parseReplay, type Replay, type ReplayCase } from './replay';

/** A player for curated development recordings, never a second simulation engine. */
export function SimDemo() {
  const [cases, setCases] = useState<ReplayCase[]>([]);
  const [selected, setSelected] = useState('');
  const [replay, setReplay] = useState<Replay>();
  const [index, setIndex] = useState(0);
  const [running, setRunning] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const controller = new AbortController();
    fetch('/replays/index.json', { signal: controller.signal })
      .then((response) => { if (!response.ok) throw new Error('The recorded displays could not be loaded.'); return response.json(); })
      .then((value) => {
        if (controller.signal.aborted) return;
        const available = parseIndex(value);
        setCases(available);
        setSelected(available[0]?.id ?? '');
        if (!available.length) setLoading(false);
      })
      .catch((cause) => { if (!controller.signal.aborted) { setError(String(cause.message)); setLoading(false); } });
    return () => controller.abort();
  }, []);

  useEffect(() => {
    const chosen = cases.find((item) => item.id === selected);
    if (!chosen) return;
    const controller = new AbortController();
    setLoading(true);
    setError('');
    setRunning(false);
    setReplay(undefined);
    setIndex(0);
    fetch(chosen.path, { signal: controller.signal })
      .then((response) => { if (!response.ok) throw new Error('This recording could not be loaded.'); return response.json(); })
      .then((value) => { if (!controller.signal.aborted) { setReplay(parseReplay(value, chosen)); setLoading(false); } })
      .catch((cause) => { if (!controller.signal.aborted) { setError(String(cause.message)); setLoading(false); } });
    return () => controller.abort();
  }, [cases, selected]);

  useEffect(() => {
    if (!running || !replay) return;
    const timer = window.setInterval(() => {
      setIndex((current) => nextFrame(current, replay.frames.length));
    }, 100 / speed);
    return () => window.clearInterval(timer);
  }, [running, replay, speed]);

  useEffect(() => {
    if (replay && index === replay.frames.length - 1) setRunning(false);
  }, [index, replay]);

  const frame = replay?.frames[index];
  const disabled = loading || !frame;
  const button = 'flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-grid text-ink transition-colors hover:bg-paper focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal disabled:opacity-40';

  return (
    <section aria-label="Recorded Quadrants displays" className="overflow-hidden rounded-xl border border-grid bg-paper text-ink">
      <div className="flex flex-wrap items-center gap-2 border-b border-grid bg-card px-3 py-2">
        <button type="button" className={button} disabled={disabled} aria-label={running ? 'Pause recording' : 'Play recording'}
          onClick={() => { if (replay && index === replay.frames.length - 1) setIndex(0); setRunning(!running); }}>
          {running ? <Pause size={14} weight="fill" /> : <Play size={14} weight="fill" />}
        </button>
        <button type="button" className={button} disabled={disabled} aria-label="Next recorded frame"
          onClick={() => { setRunning(false); setIndex(nextFrame(index, replay?.frames.length ?? 0)); }}><SkipForward size={14} weight="fill" /></button>
        <button type="button" className={button} disabled={disabled} aria-label="Reset recording"
          onClick={() => { setRunning(false); setIndex(0); }}><ArrowCounterClockwise size={14} /></button>
        <label className="min-w-0 flex-1 text-xs">
          <span className="sr-only">Recorded case</span>
          <select aria-label="Recorded case" className="w-full rounded-md border border-grid bg-card px-2 py-1.5 text-ink" value={selected}
            onChange={(event) => setSelected(event.target.value)} disabled={!cases.length}>
            {!cases.length && <option value="">Recorded displays</option>}
            {cases.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}
          </select>
        </label>
        <label className="text-xs text-ink-soft">Speed <select aria-label="Playback speed" value={speed} className="rounded-md border border-grid bg-card px-1 py-1.5 text-ink"
          onChange={(event) => setSpeed(Number(event.target.value))}>
          {[0.5, 1, 2, 4].map((value) => <option key={value} value={value}>{value}×</option>)}
        </select></label>
      </div>
      <div className="bl-replay-canvas p-2.5 sm:p-3">
        {loading && <div role="status" className="grid h-full place-items-center rounded-lg border border-grid bg-card text-sm text-ink-soft">Loading the recording…</div>}
        {error && <div role="alert" className="grid h-full place-items-center px-4 text-sm text-ink-soft">{error}</div>}
        {!loading && !error && !frame && <div className="grid h-full place-items-center text-sm text-ink-soft">Development recordings have not been published yet.</div>}
        {frame && replay && <TaskCanvas key={`${selected}:${index}`} task={replay.task} frame={frame} />}
      </div>
      <div className="space-y-3 border-t border-grid bg-card px-3 py-3">
        <label className="flex items-center gap-3 text-xs text-ink-soft">
          <span className="shrink-0 font-mono">Tick {frame?.tick ?? 0}</span>
          <input aria-label="Recorded frame" type="range" className="min-w-0 flex-1 accent-teal" min={0} max={Math.max(0, (replay?.frames.length ?? 1) - 1)} value={index} disabled={disabled}
            onChange={(event) => { setRunning(false); setIndex(Number(event.target.value)); }} />
          <span className="shrink-0 font-mono">{index + (frame ? 1 : 0)} / {replay?.frames.length ?? 0}</span>
        </label>
        {frame && <div className="flex flex-wrap gap-x-5 gap-y-1 font-mono text-[11px] text-ink-soft">
          <span>Activity {(frame.activity.reduce((sum, value) => sum + value, 0) / frame.activity.length).toFixed(3)}</span>
          <span>{frame.activity.length} nodes</span>
          <span>Effectors {frame.effectors.map((value) => value.toFixed(2)).join(', ')}</span>
        </div>}
        <p className="text-[11px] leading-relaxed text-ink-soft">Recorded Quadrants development run. Playback illustrates the recorded trajectory; it is not evidence of learning or benchmark confirmation.</p>
        {replay && <details className="text-[11px] text-ink-soft">
          <summary className="cursor-pointer focus-visible:outline-teal">Recording provenance</summary>
          <p className="mt-2">Quadrants {replay.provenance.quadrants_version}, {replay.provenance.backend}, {replay.provenance.dtype}, {replay.provenance.seed_partition} seeds.</p>
          <pre className="mt-2 max-h-32 overflow-auto whitespace-pre-wrap break-words font-mono text-[10px]">{JSON.stringify(replay.provenance.resolved, null, 2)}</pre>
          <a className="mt-2 inline-block underline" href={cases.find((item) => item.id === selected)?.path}>Download this recording</a>
        </details>}
      </div>
    </section>
  );
}
