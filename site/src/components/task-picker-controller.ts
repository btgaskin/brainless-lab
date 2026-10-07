/** A small single-select listbox; focus moves through options before commitment. */
class TaskPicker extends HTMLElement {
  private trigger?: HTMLButtonElement;
  private menu?: HTMLElement;
  private label?: HTMLElement;
  private options: HTMLButtonElement[] = [];
  private lifecycle?: AbortController;
  private activeIndex = 0;

  connectedCallback() {
    if (this.lifecycle) return;
    this.trigger = this.querySelector<HTMLButtonElement>('.task-picker-trigger') ?? undefined;
    this.menu = this.querySelector<HTMLElement>('.task-picker-menu') ?? undefined;
    this.label = this.querySelector<HTMLElement>('.task-picker-label') ?? undefined;
    this.options = Array.from(this.querySelectorAll<HTMLButtonElement>('[role="option"]'));
    if (!this.trigger || !this.menu || !this.label || !this.options.length) return;
    this.lifecycle = new AbortController();
    const { signal } = this.lifecycle;
    this.trigger.disabled = false;
    this.trigger.addEventListener('click', () => {
      if (this.menu!.hidden) this.open();
      else this.close();
    }, { signal });
    this.addEventListener('keydown', (event) => this.onKey(event), { signal });
    this.options.forEach((option, index) => {
      option.addEventListener('click', () => this.choose(index), { signal });
      option.addEventListener('focus', () => { this.activeIndex = index; }, { signal });
    });
    document.addEventListener('pointerdown', (event) => {
      if (event.target instanceof Node && !this.contains(event.target)) this.close();
    }, { signal });
    this.addEventListener('focusout', (event) => {
      if (!(event.relatedTarget instanceof Node) || !this.contains(event.relatedTarget)) this.close();
    }, { signal });
    window.addEventListener('resize', () => this.close(), { signal });
  }

  disconnectedCallback() {
    this.lifecycle?.abort();
    this.lifecycle = undefined;
    this.close();
    if (this.trigger) this.trigger.disabled = true;
  }

  private open(index?: number) {
    if (!this.menu || !this.trigger) return;
    const bounds = this.trigger.getBoundingClientRect();
    const headers = Array.from(document.querySelectorAll('header, mobile-starlight-toc nav'));
    const ceiling = Math.max(8, ...headers.map((element) => {
      const rect = element.getBoundingClientRect();
      return rect.height > 0 ? rect.bottom + 8 : 8;
    }));
    const above = Math.max(0, bounds.top - ceiling - 6);
    const below = Math.max(0, window.innerHeight - bounds.bottom - 14);
    const upwards = above >= 96 || above >= below;
    this.toggleAttribute('data-opens-down', !upwards);
    this.style.setProperty('--picker-space', `${Math.max(44, upwards ? above : below)}px`);
    this.menu.hidden = false;
    this.trigger.setAttribute('aria-expanded', 'true');
    const selected = this.options.findIndex((option) => option.dataset.value === this.dataset.value);
    this.focusOption(index ?? Math.max(0, selected));
  }

  private close(restoreFocus = false) {
    if (!this.menu || !this.trigger) return;
    this.menu.hidden = true;
    this.trigger.setAttribute('aria-expanded', 'false');
    this.options.forEach((option) => { option.tabIndex = -1; });
    if (restoreFocus) this.trigger.focus();
  }

  private focusOption(index: number) {
    this.activeIndex = (index + this.options.length) % this.options.length;
    this.options.forEach((option, current) => { option.tabIndex = current === this.activeIndex ? 0 : -1; });
    this.options[this.activeIndex]?.focus();
  }

  private choose(index: number) {
    const option = this.options[index];
    if (!option || !this.trigger || !this.label) return;
    const changed = this.dataset.value !== option.dataset.value;
    this.dataset.value = option.dataset.value;
    this.dataset.label = option.dataset.label;
    this.label.textContent = option.dataset.label ?? option.textContent;
    this.trigger.setAttribute('aria-label', `Task: ${this.dataset.label}`);
    this.options.forEach((item) => {
      item.setAttribute('aria-selected', String(item === option));
    });
    this.close(true);
    if (changed) this.dispatchEvent(new CustomEvent('task-change', { bubbles: true }));
  }

  private onKey(event: KeyboardEvent) {
    if (!this.menu || !this.trigger) return;
    const open = !this.menu.hidden;
    if (event.key === 'Escape' && open) {
      event.preventDefault();
      event.stopPropagation();
      this.close(true);
      return;
    }
    // The browser handles Tab normally; focusout closes when focus leaves the picker.
    if (event.key === 'Tab') return;
    if ((event.key === 'Enter' || event.key === ' ') && open && event.target !== this.trigger) {
      event.preventDefault();
      this.choose(this.activeIndex);
      return;
    }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      const selected = Math.max(0, this.options.findIndex((option) => option.dataset.value === this.dataset.value));
      let index = open ? this.activeIndex : selected;
      if (event.key === 'Home') index = 0;
      else if (event.key === 'End') index = this.options.length - 1;
      else if (open) index += event.key === 'ArrowDown' ? 1 : -1;
      this.open(index);
      return;
    }
    if (event.key.length === 1 && /[a-z]/i.test(event.key) && !event.ctrlKey && !event.altKey && !event.metaKey) {
      const start = open ? this.activeIndex + 1 : 0;
      for (let offset = 0; offset < this.options.length; offset++) {
        const index = (start + offset) % this.options.length;
        if (this.options[index]?.dataset.label?.toLowerCase().startsWith(event.key.toLowerCase())) {
          event.preventDefault();
          this.open(index);
          break;
        }
      }
    }
  }
}

if (!customElements.get('task-picker')) customElements.define('task-picker', TaskPicker);
