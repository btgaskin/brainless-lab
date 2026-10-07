/** User-controlled task illustrations. Motion pauses offscreen and in background tabs. */
class TaskPreview extends HTMLElement {
  private picker?: HTMLElement;
  private stage?: HTMLElement;
  private observer?: IntersectionObserver;
  private reducedMotion?: MediaQueryList;
  private playing = false;
  private visible = false;

  connectedCallback() {
    this.picker = this.querySelector<HTMLElement>('task-picker') ?? undefined;
    this.stage = this.querySelector<HTMLElement>('.preview-stage') ?? undefined;
    if (!this.picker || !this.stage) return;
    this.picker.addEventListener('task-change', this.selectTask);
    this.stage.setAttribute('role', 'button');
    this.stage.tabIndex = 0;
    this.stage.addEventListener('click', this.togglePlay);
    this.stage.addEventListener('keydown', this.handleKey);
    document.addEventListener('visibilitychange', this.sync);
    this.reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
    this.reducedMotion.addEventListener('change', this.motionPreferenceChanged);
    this.observer = new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      this.sync();
    });
    this.observer.observe(this);
    this.selectTask();
  }

  disconnectedCallback() {
    this.observer?.disconnect();
    this.picker?.removeEventListener('task-change', this.selectTask);
    this.stage?.removeEventListener('click', this.togglePlay);
    this.stage?.removeEventListener('keydown', this.handleKey);
    document.removeEventListener('visibilitychange', this.sync);
    this.reducedMotion?.removeEventListener('change', this.motionPreferenceChanged);
    this.removeAttribute('data-running');
  }

  private selectTask = () => {
    const selected = this.picker?.dataset.value;
    this.querySelectorAll('[data-task]').forEach((element) => {
      element.toggleAttribute('hidden', element.getAttribute('data-task') !== selected);
    });
    const label = this.picker?.dataset.label;
    this.querySelector('svg')?.setAttribute('aria-label', `${label} task illustration`);
    const page = this.querySelector<SVGGElement>(`svg [data-task="${selected}"]`)?.dataset.page;
    if (page) this.querySelector<HTMLAnchorElement>('[data-task-link]')?.setAttribute('href', page);
    this.playing = !this.reducedMotion?.matches;
    this.resetMotion();
    this.sync();
  };

  private togglePlay = () => {
    this.playing = !this.playing;
    this.sync();
  };

  private motionPreferenceChanged = (event: MediaQueryListEvent) => {
    if (event.matches) {
      this.playing = false;
      this.sync();
    }
  };

  private handleKey = (event: KeyboardEvent) => {
    if (event.key === ' ' || event.key === 'Enter') {
      event.preventDefault();
      this.togglePlay();
    } else if (event.key === 'Escape') {
      this.playing = false;
      this.sync();
    }
  };

  private resetMotion() {
    this.classList.add('resetting');
    // One layout read on task selection, never in a frame loop.
    void this.offsetWidth;
    this.classList.remove('resetting');
  }

  private sync = () => {
    this.toggleAttribute('data-running', this.playing && this.visible && document.visibilityState === 'visible');
    this.stage?.setAttribute('aria-label', `${this.playing ? 'Pause' : 'Play'} ${this.picker?.dataset.label} illustration`);
  };
}

if (!customElements.get('task-preview')) customElements.define('task-preview', TaskPreview);
