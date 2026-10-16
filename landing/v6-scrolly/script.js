(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const mobileMQ = matchMedia('(max-width: 900px)');

  const PROFILES = [
    { letter: 'N', color: '#5856D6', name: 'Trabalho Acme', since: 'Ativo desde 09:12', email: 'ana@acme.dev', gh: 'ana-acme', claude: 'Claude · Acme', dir: '~/.claude-acme' },
    { letter: 'P', color: '#D9770B', name: 'Pessoal', since: 'Ativo desde 14:33', email: 'ana.silva@gmail.com', gh: 'anasilva', claude: 'Claude · Pessoal', dir: '~/.claude-pessoal' },
    { letter: 'X', color: '#0E8A9E', name: 'Cliente X', since: 'Ativo desde 16:05', email: 'ana@clientex.com', gh: 'ana-clientex', claude: 'Claude · Cliente X', dir: '~/.claude-clientex' },
  ];

  /* ---------- Build the desks: one in the sticky stage, one per chapter for mobile ---------- */
  const tpl = $('#desk-tpl');
  function mountDesk(host, ch) {
    host.innerHTML = '';
    const wrap = host.classList.contains('desk-wrap') ? host : document.createElement('div');
    if (wrap !== host) { wrap.className = 'desk-wrap'; host.appendChild(wrap); }
    const desk = tpl.content.firstElementChild.cloneNode(true);
    desk.dataset.ch = ch;
    wrap.appendChild(desk);
    new ResizeObserver(() => wrap.style.setProperty('--s', wrap.clientWidth / 900 || 1)).observe(wrap);
    return desk;
  }
  const stageDesk = mountDesk($('#stage-desk'), 1);
  $$('.fig').forEach((f) => mountDesk(f, f.dataset.ch));
  const allDesks = () => $$('.desk');
  const activeDesk3 = () => (mobileMQ.matches ? $('.fig[data-ch="3"] .desk') : stageDesk);

  /* ---------- Profile state (drives every [data-bind] on the page) ---------- */
  let current = -1;
  const hudTimers = new WeakMap();
  function setProfile(i, hudDesk) {
    if (i === current && !hudDesk) return;
    const first = current === -1;
    const changed = i !== current;
    current = i;
    const p = PROFILES[i];
    document.documentElement.style.setProperty('--prof', p.color);
    $$('[data-bind]').forEach((el) => {
      const key = el.dataset.bind;
      if (key === 'badge') el.textContent = p.letter;
      else if (p[key] !== undefined && el.textContent !== p[key]) {
        el.textContent = p[key];
        if (!first && changed) {
          const t = el.closest('.out') || el.closest('li');
          if (t) { t.classList.remove('flash'); void t.offsetWidth; t.classList.add('flash'); }
        }
      }
    });
    $$('.mi[data-profile]').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    if (hudDesk && !reduced) {
      const h = $('.hud', hudDesk);
      h.classList.add('show');
      clearTimeout(hudTimers.get(h));
      hudTimers.set(h, setTimeout(() => h.classList.remove('show'), 1500));
    }
  }
  setProfile(0);

  /* ---------- Autoplay in chapter 3: cursor glides, clicks, everything switches ---------- */
  let pausedUntil = 0;
  let apInterval, apTimeout;
  function glideTo(desk, i) {
    const item = $$('.mi[data-profile]', desk)[i];
    const menu = $('.menu', desk);
    const c = $('.cursor', desk);
    c.style.left = `${menu.offsetLeft + item.offsetLeft + item.offsetWidth * 0.45}px`;
    c.style.top = `${menu.offsetTop + item.offsetTop + item.offsetHeight * 0.4}px`;
  }
  function step() {
    if (Date.now() < pausedUntil || chapter !== 3) return;
    const desk = activeDesk3();
    if (!desk) return;
    const next = (current + 1) % PROFILES.length;
    glideTo(desk, next);
    setTimeout(() => {
      if (chapter !== 3) return;
      const c = $('.cursor', desk);
      c.classList.add('click');
      setProfile(next, desk);
      setTimeout(() => c.classList.remove('click'), 350);
    }, 1050);
  }
  function stopAuto() { clearInterval(apInterval); clearTimeout(apTimeout); apInterval = apTimeout = null; }
  function startAuto() {
    stopAuto();
    if (reduced) return;
    apTimeout = setTimeout(() => { step(); apInterval = setInterval(step, 4300); }, 1300);
  }
  document.addEventListener('click', (e) => {
    const b = e.target.closest('.mi[data-profile]');
    if (!b) return;
    pausedUntil = Date.now() + 12000;
    setProfile(+b.dataset.profile, b.closest('.desk'));
  });

  /* ---------- Chapters: IntersectionObserver picks the one crossing the middle ---------- */
  const chapters = $$('.chapter');
  const rail = $$('#rail a');
  const stage = $('#stage');
  let chapter = 0;
  function setChapter(n) {
    if (n === chapter) return;
    chapter = n;
    document.body.dataset.ch = n;
    stage.dataset.ch = n;
    stageDesk.dataset.ch = n;
    chapters.forEach((c) => c.classList.toggle('on', +c.dataset.ch === n));
    rail.forEach((a) => a.classList.toggle('on', +a.dataset.ch === n));
    if (n === 3) { setProfile(0); startAuto(); } else { stopAuto(); allDesks().forEach((d) => $('.cursor', d).classList.remove('click')); }
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) setChapter(+e.target.dataset.ch); });
  }, { rootMargin: '-45% 0px -45% 0px' });
  chapters.forEach((c) => io.observe(c));
  setChapter(1);

  // On mobile there is no stage: figs show each chapter's own scene and the cursor loop
  // still needs a chapter-3 desk, so start/stop follows the same observer.

  /* ---------- Scroll progress: rail fill + 3D parallax on the desk ---------- */
  const story = $('#story');
  const tilt = $('#tilt');
  const railEl = $('#rail');
  let ticking = false;
  function onScroll() {
    $('#nav').classList.toggle('scrolled', scrollY > 20);
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      ticking = false;
      const r = story.getBoundingClientRect();
      const total = Math.max(r.height - innerHeight, 1);
      const p = Math.min(Math.max(-r.top / total, 0), 1);
      railEl.style.setProperty('--prog', p.toFixed(4));
      if (!reduced && !mobileMQ.matches) {
        const ry = -9 + 7 * Math.sin(p * Math.PI * 3.5);
        const rx = 3 + 2 * Math.cos(p * Math.PI * 2.5);
        tilt.style.setProperty('--ry', `${ry.toFixed(2)}deg`);
        tilt.style.setProperty('--rx', `${rx.toFixed(2)}deg`);
      }
    });
  }
  onScroll();
  addEventListener('scroll', onScroll, { passive: true });

  /* ---------- Bokeh ---------- */
  const bokeh = $('#bokeh');
  if (bokeh) {
    for (let i = 0; i < 16; i++) {
      const el = document.createElement('i');
      const s = 40 + Math.random() * 120;
      el.style.cssText = `left:${Math.random() * 100}%;top:${Math.random() * 100}%;width:${s}px;height:${s}px;--b:${4 + Math.random() * 8}px;--o:${0.04 + Math.random() * 0.08};--t:${12 + Math.random() * 14}s;--dx:${(Math.random() - 0.5) * 120}px;--dy:${-30 - Math.random() * 80}px;animation-delay:${-Math.random() * 12}s`;
      bokeh.appendChild(el);
    }
  }

  /* ---------- Install card lives in the stage on desktop, in its own section on mobile ---------- */
  const install = $('#install');
  const slots = { desktop: $('#inst-desktop'), mobile: $('#inst-mobile') };
  function placeInstall() {
    const target = mobileMQ.matches ? slots.mobile : slots.desktop;
    if (install.parentElement !== target) target.appendChild(install);
    $$('.fig .desk-wrap').forEach((w) => w.style.setProperty('--s', w.clientWidth / 900 || 1));
  }
  placeInstall();
  mobileMQ.addEventListener('change', placeInstall);

  $$('.os').forEach((b) => b.addEventListener('click', () => {
    $$('.os').forEach((o) => { o.classList.toggle('on', o === b); o.setAttribute('aria-selected', o === b); });
    $$('.os-panel').forEach((p) => p.classList.toggle('on', p.id === `os-${b.dataset.os}`));
  }));
  $$('.copy').forEach((b) => b.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(b.parentElement.dataset.copy); } catch { /* clipboard blocked */ }
    b.textContent = 'Copiado ✓'; b.classList.add('done');
    setTimeout(() => { b.textContent = 'Copiar'; b.classList.remove('done'); }, 1800);
  }));
  $('#wait')?.addEventListener('submit', (e) => {
    e.preventDefault();
    const input = e.target.querySelector('input');
    const msg = $('#wait-msg');
    if (!input.value || !input.checkValidity()) { msg.textContent = 'Digite um e-mail válido.'; msg.style.color = 'var(--red)'; return; }
    msg.textContent = 'Anotado! Avisamos quando a versão Ubuntu sair.'; msg.style.color = 'var(--green)';
    input.value = '';
  });
  $('#dl-mac')?.addEventListener('click', (e) => { if (e.currentTarget.getAttribute('href') === '#') e.preventDefault(); });

  /* ---------- Reveal for the regular sections ---------- */
  const rio = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); rio.unobserve(e.target); } });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  $$('.reveal').forEach((el) => rio.observe(el));
})();
