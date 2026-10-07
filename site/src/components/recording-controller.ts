interface DataConnection extends EventTarget { saveData?: boolean }

const FINAL_OPACITY = 0.8;

/** Owns automatic playback and explicit replays of the source recording. */
class NeuronRecording extends HTMLElement {
  private video?: HTMLVideoElement;
  private visual?: HTMLElement;
  private posterReady = false;
  private abort?: AbortController;
  private observer?: IntersectionObserver;
  private motion = matchMedia('(prefers-reduced-motion: reduce)');
  private connection = (navigator as Navigator & { connection?: DataConnection }).connection;
  private visible = false;
  private scrollOpacity = 1;
  private footageOpacity = 1;
  private manuallyPaused = false;
  private explicitlyEnabled = false;
  private blocked = false;
  private finished = false;
  private pending = false;
  private ownedPauses = 0;
  private request = 0;
  private fadeFrame = 0;
  private videoFrame?: number;

  connectedCallback() {
    if (this.abort) return;
    this.video = this.querySelector<HTMLVideoElement>('.recording-enhanced') ?? undefined;
    if (!this.video) return;
    this.visual = this.querySelector<HTMLElement>('.recording-visual') ?? undefined;
    this.abort = new AbortController();
    const lifecycle = this.abort;
    const signal = lifecycle.signal;
    this.video.controls = false;
    this.video.muted = true;
    this.video.loop = false;
    const restart = () => {
      ++this.request;
      this.pending = false;
      this.cancelFrames();
      this.finished = false;
      this.footageOpacity = 1;
      this.manuallyPaused = false;
      this.explicitlyEnabled = true;
      this.blocked = false;
      if (this.video!.error) this.video!.load();
      this.video!.currentTime = 0;
      this.applyOpacity();
      this.sync();
      if (!this.video!.paused) this.trackFrames();
    };
    this.video.addEventListener('click', restart, { signal });
    this.video.addEventListener('keydown', (event) => {
      if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); restart(); }
      if (event.key === 'Escape') {
        event.preventDefault();
        this.manuallyPaused = true;
        this.explicitlyEnabled = false;
        this.sync();
      }
    }, { signal });
    this.video.addEventListener('playing', () => {
      if (!this.video!.requestVideoFrameCallback && this.video!.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
        this.revealFrame();
      }
      this.updateAction();
      this.trackFrames();
    }, { signal });
    this.video.addEventListener('pause', () => {
      const owned = this.ownedPauses > 0;
      if (owned) --this.ownedPauses;
      if (!this.video!.paused) return;
      this.cancelFrames();
      if (!owned && this.wanted() && !this.pending) this.manuallyPaused = true;
      this.updateAction();
    }, { signal });
    this.video.addEventListener('ended', () => {
      if (!this.video!.ended) return;
      this.finished = true;
      this.footageOpacity = FINAL_OPACITY;
      this.cancelFrames();
      this.applyOpacity();
      this.updateAction();
    }, { signal });
    this.video.addEventListener('error', () => {
      this.blocked = true;
      this.showError('This recording could not play. You can open the source recording.');
      this.sync();
    }, { signal });
    this.video.addEventListener('timeupdate', () => {
      if (!this.video!.requestVideoFrameCallback) this.updateFootage(this.video!.currentTime);
    }, { signal });
    const preferences = () => {
      if (this.motion.matches || this.connection?.saveData) this.explicitlyEnabled = false;
      this.scheduleFade();
      this.sync();
    };
    this.motion.addEventListener('change', preferences, { signal });
    this.connection?.addEventListener('change', preferences, { signal });
    document.addEventListener('visibilitychange', () => this.sync(), { signal });
    window.addEventListener('scroll', this.scheduleFade, { passive: true, signal });
    window.addEventListener('resize', this.scheduleFade, { passive: true, signal });
    this.observer = new IntersectionObserver(([entry]) => {
      if (this.abort !== lifecycle) return;
      this.visible = entry.isIntersecting;
      this.sync();
    });
    this.observer.observe(this);
    // Let the small, prioritised still finish before competing for video bandwidth.
    const poster = this.querySelector<HTMLImageElement>('.recording-poster');
    if (poster) {
      void poster.decode().catch(() => {}).then(() => {
        if (this.abort !== lifecycle) return;
        this.posterReady = true;
        this.sync();
      });
    } else {
      this.posterReady = true;
    }
    this.scheduleFade();
    this.updateAction();
    this.applyOpacity();
  }

  disconnectedCallback() {
    this.abort?.abort();
    this.abort = undefined;
    this.observer?.disconnect();
    this.observer = undefined;
    cancelAnimationFrame(this.fadeFrame);
    this.fadeFrame = 0;
    ++this.request;
    this.pending = false;
    this.visible = false;
    this.posterReady = false;
    this.removeAttribute('data-frame-ready');
    this.cancelFrames();
    if (this.video) {
      this.pauseOwned();
      this.video.removeAttribute('src');
      this.video.load();
      this.video.controls = true;
    }
    this.ownedPauses = 0;
  }

  private wanted() {
    return this.isConnected && !document.hidden && this.visible && this.scrollOpacity > 0 &&
      !this.finished && !this.manuallyPaused && !this.blocked &&
      (this.explicitlyEnabled || (!this.motion.matches && !this.connection?.saveData));
  }

  private pauseOwned() {
    if (this.video && !this.video.paused) {
      ++this.ownedPauses;
      this.video.pause();
    }
    this.cancelFrames();
  }

  private sync() {
    const video = this.video;
    if (!video) return;
    if (!this.wanted()) {
      ++this.request;
      this.pending = false;
      this.pauseOwned();
    } else if (video.paused && !this.pending && (this.posterReady || this.explicitlyEnabled)) {
      if (!video.hasAttribute('src')) {
        video.src = (matchMedia('(max-width: 55.999rem)').matches ? this.dataset.mobile : this.dataset.desktop)!;
      }
      this.pending = true;
      void this.play(++this.request);
    }
    this.updateAction();
  }

  private async play(request: number) {
    try {
      await this.video!.play();
      if (request !== this.request || !this.isConnected) return;
      this.pending = false;
      this.showError('');
      if (!this.wanted()) this.pauseOwned();
    } catch (error) {
      if (request !== this.request || !this.isConnected) return;
      this.pending = false;
      if (!(error instanceof DOMException && error.name === 'AbortError')) {
        this.blocked = true;
        if (!(error instanceof DOMException && error.name === 'NotAllowedError')) {
          this.showError('This recording could not play. You can open the source recording.');
        }
      }
    }
    this.updateAction();
  }

  private updateAction() {
    if (!this.video) return;
    this.video.tabIndex = 0;
    this.video.setAttribute('role', 'button');
    this.video.setAttribute('aria-label', 'Restart neuron growth recording');
    this.video.setAttribute('aria-description', 'Click or press Enter or Space to restart. Press Escape to pause.');
  }

  private trackFrames() {
    if (this.videoFrame !== undefined || !this.video?.requestVideoFrameCallback || this.video.paused || this.finished) return;
    const lifecycle = this.abort;
    const request = this.request;
    this.videoFrame = this.video.requestVideoFrameCallback((_now, metadata) => {
      this.videoFrame = undefined;
      if (!lifecycle || this.abort !== lifecycle || request !== this.request || !this.wanted() || this.video!.paused) return;
      this.revealFrame();
      this.updateFootage(metadata.mediaTime);
      this.trackFrames();
    });
  }

  private cancelFrames() {
    if (this.videoFrame !== undefined) this.video?.cancelVideoFrameCallback?.(this.videoFrame);
    this.videoFrame = undefined;
  }

  private revealFrame() {
    this.setAttribute('data-frame-ready', '');
  }

  private updateFootage(time: number) {
    const duration = this.video?.duration ?? 0;
    if (duration > 0 && Number.isFinite(duration)) {
      const t = Math.min(1, Math.max(0, (time / duration - 0.9) / 0.1));
      this.footageOpacity = this.finished ? FINAL_OPACITY : 1 - (1 - FINAL_OPACITY) * t * t * (3 - 2 * t);
      this.applyOpacity();
    }
  }

  private applyOpacity() {
    if (this.visual) this.visual.style.opacity = String(this.scrollOpacity * this.footageOpacity);
  }

  private showError(message: string) {
    const status = this.querySelector<HTMLElement>('.recording-status');
    if (status) { status.textContent = message; status.hidden = !message; }
  }

  private scheduleFade = () => {
    if (this.fadeFrame) return;
    this.fadeFrame = requestAnimationFrame(() => {
      this.fadeFrame = 0;
      if (!this.isConnected) return;
      const rect = (this.closest('.bl-home-opening') ?? this).getBoundingClientRect();
      const fade = this.motion.matches ? 0 : Math.min(1, Math.max(0, -rect.top / Math.max(1, rect.height * 0.7)));
      this.scrollOpacity = 1 - fade;
      this.applyOpacity();
      this.sync();
    });
  };
}

if (!customElements.get('neuron-recording')) customElements.define('neuron-recording', NeuronRecording);
