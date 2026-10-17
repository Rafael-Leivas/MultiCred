(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const isMobile = () => matchMedia('(max-width: 900px)').matches;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const smooth = (a, b, v) => { const t = clamp((v - a) / (b - a)); return t * t * (3 - 2 * t); };
  const root = document.documentElement;

  // `?cap=N` pins the page to chapter N (used for screenshots in headless browsers that can't scroll)
  const forcedParam = new URLSearchParams(location.search).get('cap');
  const forced = forcedParam !== null && !Number.isNaN(+forcedParam) ? clamp(+forcedParam, 0, 6) : null;

  const PROFILES = [
    { letter: 'N', color: '#5856D6', name: 'Trabalho Acme', email: 'ana@acme.dev', gh: 'ana-acme', claude: 'Claude · Acme', dir: '~/.claude-acme' },
    { letter: 'P', color: '#D9770B', name: 'Pessoal', email: 'ana.silva@gmail.com', gh: 'anasilva', claude: 'Claude · Pessoal', dir: '~/.claude-pessoal' },
    { letter: 'X', color: '#0E8A9E', name: 'Cliente X', email: 'ana@clientex.com', gh: 'ana-clientex', claude: 'Claude · Cliente X', dir: '~/.claude-clientex' },
  ];
  const CHAP_PROF = [1, 0, 2, 0, 2, 1, 1];
  const TIMES = [510, 552, 700, 840, 1065, 1230, 1320]; // 08:30 09:12 11:40 14:00 17:45 20:30 22:00
  const fmt = (m) => {
    const r = Math.round(m);
    return `${String(Math.floor(r / 60)).padStart(2, '0')}:${String(r % 60).padStart(2, '0')}`;
  };

  const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const SKY = [
    ['#f6c1a8', '#fbd9b8', '#fff2dc', '#e9a98f', '#d98f78'], // 08:30 dawn
    ['#a8d4ff', '#cfe8ff', '#f3f9ff', '#9cc4e6', '#86b3d6'], // 09:12 morning
    ['#5eb4ff', '#9bd3ff', '#e4f4ff', '#6fb0e0', '#5a9cd0'], // 11:40 noon
    ['#7cc0f5', '#bfe0f5', '#fff3cf', '#8fb8c8', '#7aa6b8'], // 14:00 afternoon
    ['#2d2a5f', '#b4496c', '#f6a65a', '#3a2450', '#2a1a3d'], // 17:45 sunset
    ['#0d1230', '#1c2352', '#3a2f66', '#151236', '#0e0c28'], // 20:30 dusk
    ['#050818', '#0b1030', '#161a45', '#0a0c26', '#06081c'], // 22:00 night
  ].map((row) => row.map(hex));
  const mix = (a, b, f) => `rgb(${a.map((v, k) => Math.round(v + (b[k] - v) * f)).join(',')})`;

  // ---------- Stars ----------
  const stars = $('#stars');
  for (let k = 0; k < 70; k++) {
    const s = document.createElement('span');
    s.style.cssText = `left:${(Math.random() * 100).toFixed(1)}%;top:${(Math.random() * 62).toFixed(1)}%;animation-delay:${(Math.random() * 3).toFixed(1)}s;opacity:${(0.4 + Math.random() * 0.6).toFixed(2)}`;
    stars.appendChild(s);
  }

  // ---------- Desk state ----------
  const desk = $('#desk');
  const STATE_CLASSES = ['s-hud', 's-contas', 's-login', 's-key', 's-warn', 's-notif'];

  function refresh(d) {
    const cap = d.dataset.cap;
    $$('.el', d).forEach((el) => {
      const inCap = el.dataset.show.split(' ').includes(cap);
      const needOk = !el.dataset.need || d.classList.contains(el.dataset.need);
      const hidden = el.dataset.hideOn && d.classList.contains(el.dataset.hideOn);
      el.classList.toggle('show', inCap && needOk && !hidden);
    });
  }
  function flag(d, name, on = true) { d.classList.toggle(name, on); refresh(d); }

  function setProfile(d, idx, { flash = false, time = '08:30' } = {}) {
    const p = PROFILES[idx];
    d.dataset.prof = idx;
    d.style.setProperty('--pc', p.color);
    $$('[data-b]', d).forEach((el) => {
      const k = el.dataset.b;
      const v = k === 'badge' ? p.letter : k === 'since' ? `Ativo desde ${time}` : p[k];
      if (v === undefined || el.textContent === v) return;
      el.textContent = v;
      const row = el.classList.contains('out') ? el : el.closest('.out');
      if (flash && row) { row.classList.remove('flash'); void row.offsetWidth; row.classList.add('flash'); }
    });
    $$('.mi[data-p]', d).forEach((m) => m.classList.toggle('on', +m.dataset.p === idx));
  }

  function applyStatic(d, i) {
    STATE_CLASSES.forEach((c) => d.classList.remove(c));
    d.dataset.cap = i;
    if (i === 1) d.classList.add('s-hud');
    if (i === 2) d.classList.add('s-contas');
    if (i >= 2) d.classList.add('s-login');
    if (i === 3) d.classList.add('s-key');
    if (i === 4) d.classList.add('s-warn');
    if (i === 5) d.classList.add('s-notif');
    setProfile(d, CHAP_PROF[i], { time: fmt(TIMES[i]) });
    refresh(d);
  }

  // ---------- Mobile: one static desk per chapter ----------
  const clones = [];
  $$('.chap').forEach((chap, i) => {
    const slot = $('.mstage', chap);
    const c = desk.cloneNode(true);
    c.removeAttribute('id');
    $('.cursor', c)?.remove();
    $$('[data-clock]', c).forEach((el) => { el.removeAttribute('data-clock'); el.textContent = fmt(TIMES[i]); });
    applyStatic(c, i);
    slot.appendChild(c);
    clones.push({ slot, desk: c });
  });
  function fitClones() {
    if (!isMobile()) return;
    clones.forEach(({ slot, desk: c }) => {
      const s = slot.clientWidth / 660;
      c.style.transform = `scale(${s})`;
      slot.style.height = `${560 * s}px`;
    });
  }

  // ---------- Desktop stage scaling ----------
  function fitMain() {
    if (isMobile()) return;
    const stage = $('.stage');
    const s = Math.min(1, (stage.clientWidth - 8) / 660, (innerHeight * 0.88) / 560);
    desk.style.transform = `scale(${s})`;
    desk._s = s;
  }

  // ---------- Chapter sequences on the main desk ----------
  const cursor = $('.cursor', desk);
  let seq = 0;
  const later = (fn, ms) => { const id = seq; setTimeout(() => { if (id === seq) fn(); }, ms); };
  function cursorTo(el, { dx = 0.45, dy = 0.5 } = {}) {
    const d = desk.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const s = desk._s || 1;
    cursor.classList.add('on');
    cursor.style.left = `${(r.left - d.left + r.width * dx) / s}px`;
    cursor.style.top = `${(r.top - d.top + r.height * dy) / s}px`;
  }
  function press(el) {
    cursor.classList.add('click');
    setTimeout(() => cursor.classList.remove('click'), 350);
    el?.classList.remove('hover');
  }
  const mi = (n) => $(`.mi[data-p="${n}"]`, desk);

  function enter(i) {
    seq++;
    STATE_CLASSES.forEach((c) => desk.classList.remove(c));
    $$('.hover', desk).forEach((el) => el.classList.remove('hover'));
    cursor.classList.remove('on');
    desk.dataset.cap = i;
    if (reduced || forced !== null) { applyStatic(desk, i); return; }
    desk.classList.toggle('s-login', i >= 3);
    const t = fmt(TIMES[i]);
    const prev = CHAP_PROF[Math.max(0, i - 1)];
    // Chapters start from the previous chapter's profile, then the cursor performs the switch.
    setProfile(desk, i === 0 ? 1 : prev, { time: fmt(TIMES[Math.max(0, i - 1)]) });
    refresh(desk);

    const click = (target, idx, ms) => {
      later(() => { cursorTo(target); target.classList.add('hover'); }, ms - 700);
      later(() => { press(target); setProfile(desk, idx, { flash: true, time: t }); }, ms);
    };
    switch (i) {
      case 1:
        click(mi(0), 0, 1500);
        later(() => flag(desk, 's-hud', true), 1650);
        later(() => { flag(desk, 's-hud', false); cursor.classList.remove('on'); }, 3900);
        break;
      case 2:
        click(mi(2), 2, 1400);
        later(() => flag(desk, 's-contas', true), 2900);
        later(() => cursorTo($('.btn-enter', desk), { dx: 0.5 }), 3700);
        later(() => { $('.btn-enter', desk).classList.add('hover'); }, 4300);
        later(() => { press($('.btn-enter', desk)); flag(desk, 's-login', true); }, 4800);
        later(() => cursor.classList.remove('on'), 5800);
        break;
      case 3:
        setProfile(desk, 0, { time: t });
        later(() => flag(desk, 's-key', true), 1100);
        break;
      case 4:
        setProfile(desk, 2, { time: t });
        later(() => flag(desk, 's-warn', true), 700);
        break;
      case 5:
        click(mi(1), 1, 1400);
        later(() => flag(desk, 's-notif', true), 1700);
        later(() => cursor.classList.remove('on'), 2600);
        break;
      case 6:
        setProfile(desk, 1, { time: t });
        break;
      default:
        setProfile(desk, 1, { time: t });
    }
  }

  // ---------- Scroll progress ----------
  const chaps = $$('.chap');
  const cards = chaps.map((c) => $('.card', c));
  const story = $('#dia');
  const bigclock = $('#bigclock');
  const rail = $('#rail');
  const railFill = $('#railFill');
  const railLinks = $$('#rail a');
  const themeMeta = $('meta[name="theme-color"]');
  let activeIdx = -1;
  let phase = '';
  let lastClock = '';

  function computeP() {
    if (forced !== null) return forced;
    const vc = innerHeight * 0.5;
    let i = -1;
    const centers = cards.map((c) => { const r = c.getBoundingClientRect(); return r.top + r.height / 2; });
    centers.forEach((c, k) => { if (vc >= c) i = k; });
    if (i < 0) return 0;
    if (i >= centers.length - 1) return centers.length - 1;
    return i + (vc - centers[i]) / (centers[i + 1] - centers[i]);
  }

  function update() {
    const p = computeP();
    const i = Math.min(6, Math.floor(p));
    const f = p - i;
    const a = SKY[i], b = SKY[Math.min(6, i + 1)];
    const set = (k, v) => root.style.setProperty(k, v);
    set('--sk-t', mix(a[0], b[0], f)); set('--sk-m', mix(a[1], b[1], f)); set('--sk-b', mix(a[2], b[2], f));
    set('--hill-b', mix(a[3], b[3], f)); set('--hill-f', mix(a[4], b[4], f));

    const t1 = clamp(p / 4.7);
    set('--ox', (8 + 84 * t1).toFixed(2)); set('--oy', (74 - 56 * Math.sin(Math.PI * t1)).toFixed(2));
    set('--so', (1 - smooth(4.3, 4.9, p)).toFixed(3));
    const t2 = clamp((p - 4.4) / 1.6);
    set('--mx', (15 + 70 * t2).toFixed(2)); set('--my', (70 - 52 * Math.sin(Math.PI * t2 * 0.85)).toFixed(2));
    set('--mo', smooth(4.6, 5.3, p).toFixed(3));
    set('--star', smooth(4.2, 5.2, p).toFixed(3));
    set('--cloud', Math.max(0.05, 1 - smooth(3.6, 5, p)).toFixed(3));

    const night = p >= 3.6 ? 'night' : 'day';
    if (night !== phase) {
      phase = night;
      root.dataset.phase = night;
    }
    themeMeta.content = mix(a[1], b[1], f).replace(/rgb\((\d+),(\d+),(\d+)\)/, (_, r, g, bl) => `#${[r, g, bl].map((n) => (+n).toString(16).padStart(2, '0')).join('')}`);

    // clock
    const minutes = p <= 0 ? TIMES[0] : TIMES[i] + (TIMES[Math.min(6, i + 1)] - TIMES[i]) * (i >= 6 ? 0 : smooth(0, 1, f));
    const txt = fmt(minutes);
    if (txt !== lastClock) {
      lastClock = txt;
      $$('[data-clock]').forEach((el) => { el.textContent = txt; });
    }

    // visible bits + active chapter
    const sr = story.getBoundingClientRect();
    const inStory = forced !== null || (sr.top < innerHeight * 0.6 && sr.bottom > innerHeight * 0.4);
    bigclock.classList.toggle('on', inStory);
    rail.classList.toggle('on', inStory);
    railFill.style.height = `${(p / 6) * 100}%`;

    const idx = Math.round(clamp(p, 0, 6));
    if (idx !== activeIdx) {
      activeIdx = idx;
      root.style.setProperty('--prof', PROFILES[CHAP_PROF[idx]].color);
      chaps.forEach((c, k) => c.classList.toggle('live', k === idx));
      railLinks.forEach((l, k) => l.classList.toggle('act', k === idx));
      $('.bc-day').textContent = ['Acordando', 'Trabalho', 'Chamada com cliente', 'Chave de API', 'Sessões abertas', 'Projeto paralelo', 'Fim do dia'][idx];
      if (!isMobile()) enter(idx);
    }
  }

  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { ticking = false; update(); });
  };
  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', () => { fitMain(); fitClones(); onScroll(); });

  // Rail: scroll so the chapter card sits at the viewport centre (that is exactly its clock time)
  railLinks.forEach((l) => l.addEventListener('click', (e) => {
    e.preventDefault();
    const r = cards[+l.dataset.i].getBoundingClientRect();
    scrollTo({ top: scrollY + r.top + r.height / 2 - innerHeight / 2, behavior: reduced ? 'auto' : 'smooth' });
  }));

  if (forced !== null) {
    $('.hero').style.display = 'none';
    chaps.forEach((c, k) => { c.style.display = k === forced ? '' : 'none'; });
  }
  fitMain(); fitClones();
  update();

  // ---------- Install / FAQ helpers ----------
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
    if (!input.checkValidity() || !input.value) { msg.textContent = 'Digite um e-mail válido.'; return; }
    msg.textContent = 'Anotado! Avisamos quando a versão Ubuntu sair.';
    input.value = '';
  });
  $('#dl-mac')?.addEventListener('click', (e) => { if (e.currentTarget.getAttribute('href') === '#') e.preventDefault(); });
})();
