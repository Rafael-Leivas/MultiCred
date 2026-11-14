(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const narrow = matchMedia('(max-width: 900px)');
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const ease = (t) => t * t * (3 - 2 * t);

  // ?p=0.5 and ?q=0.5 pin the two scroll scenes (used for screenshots)
  const params = new URLSearchParams(location.search);
  const forceP = params.has('p') ? clamp(+params.get('p')) : null;
  const forceQ = params.has('q') ? clamp(+params.get('q')) : null;

  const PROFILES = [
    { letter: 'N', color: '#5856D6', name: 'Trabalho Acme', since: 'Ativo desde 09:12', email: 'ana@acme.dev', gh: 'ana-acme', claude: 'Claude · Acme', dir: '~/.claude-acme', keyname: 'ACME_OPENAI_KEY' },
    { letter: 'P', color: '#D9770B', name: 'Pessoal', since: 'Ativo desde 14:33', email: 'ana.silva@gmail.com', gh: 'anasilva', claude: 'Claude · Pessoal', dir: '~/.claude-pessoal', keyname: 'PESSOAL_OPENAI_KEY' },
    { letter: 'X', color: '#0E8A9E', name: 'Cliente X', since: 'Ativo desde 16:05', email: 'ana@clientex.com', gh: 'ana-clientex', claude: 'Claude · Cliente X', dir: '~/.claude-clientex', keyname: 'CLIENTEX_OPENAI_KEY' },
  ];

  /* ---------- Pilha de camadas (perfil em vista explodida) ---------- */
  const LAYERS_HTML = `
    <div class="layer l0" style="--i:0">
      <span class="pn">①</span>
      <span class="ly">PERFIL</span>
      <div class="id"><i class="badge" data-bind="badge">N</i><div><div class="nm" data-bind="name">Trabalho Acme</div><div class="em" data-bind="email">ana@acme.dev</div></div></div>
      <div class="bars"></div>
    </div>
    <div class="layer l1" style="--i:1">
      <span class="pn">②</span>
      <svg viewBox="0 0 24 24"><circle cx="6" cy="5" r="2.5"/><circle cx="6" cy="19" r="2.5"/><circle cx="18" cy="8" r="2.5"/><path d="M6 7.5v9M18 10.5c0 4-6 3-12 6"/></svg>
      <span class="ly">GIT</span>
      <code>user.name = <b>Ana Souza</b></code>
      <code>user.email = <b data-bind="email">ana@acme.dev</b></code>
    </div>
    <div class="layer l2" style="--i:2">
      <span class="pn">③</span>
      <svg viewBox="0 0 24 24"><path d="m8 7-5 5 5 5M16 7l5 5-5 5"/></svg>
      <span class="ly">GITHUB CLI</span>
      <code>$ gh auth switch</code>
      <code>✓ <b data-bind="gh">ana-acme</b> · github.com</code>
    </div>
    <div class="layer l3" style="--i:3">
      <span class="pn">④</span>
      <svg viewBox="0 0 24 24"><path d="M12 3c.6 5 3.4 7.8 9 9-5.6 1.2-8.4 4-9 9-.6-5-3.4-7.8-9-9 5.6-1.2 8.4-4 9-9z"/></svg>
      <span class="ly">CLAUDE CODE</span>
      <code>CLAUDE_CONFIG_DIR</code>
      <code>= <b data-bind="dir">~/.claude-acme</b></code>
    </div>
    <div class="layer l4" style="--i:4">
      <span class="pn">⑤</span>
      <svg viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>
      <span class="ly">KEYCHAIN</span>
      <code><b data-bind="keyname">ACME_OPENAI_KEY</b></code>
      <code>•••• •••• •••• ••••</code>
    </div>`;
  $$('.stack').forEach((s) => { s.innerHTML = LAYERS_HTML; });
  const heroStack = $('#heroStack');
  const stage = $('#a-stage');
  const mini = $('#mini');

  /* ---------- Troca de perfil ---------- */
  let current = -1;
  let sw = 1; // 1 = montado, 0 = desmontado (durante a troca)
  let eScroll = 0;
  let swToken = 0;

  function bind(i) {
    current = i;
    const p = PROFILES[i];
    document.documentElement.style.setProperty('--prof', p.color);
    $$('[data-bind]').forEach((el) => {
      const key = el.dataset.bind;
      if (key === 'badge') el.textContent = p.letter;
      else if (p[key] !== undefined) el.textContent = p[key];
    });
    $$('.mi[data-profile]').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    $$('.chip').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    $$('.ops li').forEach((li) => li.classList.toggle('on', +li.dataset.op === i));
    $('.mh-list')?.querySelectorAll('li').forEach((li) => { li.style.animation = 'none'; void li.offsetWidth; li.style.animation = ''; });
  }

  function tween(from, to, ms, fn, done) {
    const t0 = performance.now();
    const tick = (t) => {
      const k = clamp((t - t0) / ms);
      fn(from + (to - from) * ease(k));
      if (k < 1) requestAnimationFrame(tick); else done && done();
    };
    requestAnimationFrame(tick);
  }

  function showHud() {
    if (reduced) return;
    const h = $('#hud');
    h.classList.add('show');
    clearTimeout(showHud.t);
    showHud.t = setTimeout(() => h.classList.remove('show'), 1500);
  }

  function switchTo(i, { hud = false } = {}) {
    if (i === current) return;
    if (hud) showHud();
    if (reduced) { bind(i); return; }
    const token = ++swToken;
    tween(sw, 0, 320, (v) => { if (token === swToken) { sw = v; applyE(); } }, () => {
      if (token !== swToken) return;
      bind(i);
      tween(0, 1, 760, (v) => { if (token === swToken) { sw = v; applyE(); } });
    });
  }

  /* ---------- Folha 1: vista explodida + linhas de chamada ---------- */
  const svg = $('#leaders');
  const NS = 'http://www.w3.org/2000/svg';
  const leaderPaths = [0, 1, 2, 3, 4].map(() => {
    const path = document.createElementNS(NS, 'path');
    const dot = document.createElementNS(NS, 'circle');
    dot.setAttribute('r', 4.5);
    svg.append(path, dot);
    return { path, dot };
  });
  let leaderDraw = [0, 0, 0, 0, 0];

  function drawLeaders(e) {
    if (narrow.matches) return;
    const sr = stage.getBoundingClientRect();
    svg.setAttribute('viewBox', `0 0 ${sr.width} ${sr.height}`);
    leaderPaths.forEach(({ path, dot }, i) => {
      const layer = heroStack.children[i];
      const label = $(`.callouts li[data-layer="${i}"]`);
      if (!layer || !label) return;
      const r = layer.getBoundingClientRect();
      const lr = label.getBoundingClientRect();
      const a = { x: r.right - r.width * 0.1 - sr.left, y: r.top + r.height * 0.5 - sr.top };
      const l = { x: lr.left - sr.left - 2, y: lr.top + lr.height / 2 - sr.top };
      path.setAttribute('d', `M${a.x.toFixed(1)} ${a.y.toFixed(1)} L${(l.x - 40).toFixed(1)} ${l.y.toFixed(1)} L${l.x.toFixed(1)} ${l.y.toFixed(1)}`);
      const len = path.getTotalLength();
      const d = reduced ? 1 : clamp((e - 0.5 - i * 0.05) / 0.22);
      leaderDraw[i] = d;
      path.style.strokeDasharray = len;
      path.style.strokeDashoffset = len * (1 - d);
      dot.setAttribute('cx', a.x.toFixed(1));
      dot.setAttribute('cy', a.y.toFixed(1));
      dot.style.opacity = d > 0.02 ? 1 : 0;
    });
  }

  let pA = 0;
  function applyE() {
    const base = narrow.matches || reduced ? 1 : eScroll;
    const e = base * sw;
    stage.style.setProperty('--e', e.toFixed(3));
    mini.style.setProperty('--e', sw.toFixed(3));
    $('#dimv').textContent = Math.round(e * 74);
    drawLeaders(e);
  }

  function updateA() {
    const sceneA = $('#anatomia');
    const r = sceneA.getBoundingClientRect();
    pA = forceP !== null ? forceP : clamp(-r.top / Math.max(1, r.height - innerHeight));
    eScroll = ease(clamp((pA - 0.1) / 0.5));
    applyE();
    $('#a-fill').style.width = `${(pA * 100).toFixed(1)}%`;
    const s = pA < 0.1 ? 0 : pA < 0.6 ? 1 : 2;
    $$('.steps-s span').forEach((el) => el.classList.toggle('on', +el.dataset.s === s));
  }

  /* ---------- Folha 2: a mesa (cursor guiado pelo scroll) ---------- */
  const desk = $('#desk');
  const cursor = $('#cursor');
  let stepIdx = -1;

  function glideTo(i) {
    const item = $$('.mi[data-profile]')[i];
    if (!item) return;
    const d = desk.getBoundingClientRect();
    const r = item.getBoundingClientRect();
    cursor.style.left = `${r.left - d.left + r.width * 0.45}px`;
    cursor.style.top = `${r.top - d.top + r.height * 0.4}px`;
  }
  function autoClick(i) {
    glideTo(i);
    const go = () => {
      cursor.classList.add('click');
      switchTo(i, { hud: true });
      setTimeout(() => cursor.classList.remove('click'), 350);
    };
    reduced ? go() : setTimeout(go, 1050);
  }

  function updateB() {
    if (narrow.matches) return;
    const r = $('#operacao').getBoundingClientRect();
    const q = forceQ !== null ? forceQ : clamp(-r.top / Math.max(1, r.height - innerHeight));
    const idx = q < 0.3 ? 0 : q < 0.62 ? 1 : 2;
    if (idx !== stepIdx) {
      const first = stepIdx === -1;
      stepIdx = idx;
      // On load (before the scene was reached) only the pinned state is applied.
      if (first && idx === 0) { glideTo(0); return; }
      autoClick(idx);
    }
  }

  // Mobile / sem scroll fixo: a mesa faz o ciclo sozinha enquanto visível
  let deskVisible = false;
  new IntersectionObserver(([e]) => { deskVisible = e.isIntersecting; }, { threshold: 0.3 }).observe(desk);
  let pausedUntil = 0;
  if (!reduced) {
    setInterval(() => {
      if (!narrow.matches || !deskVisible || Date.now() < pausedUntil) return;
      autoClick((current + 1) % PROFILES.length);
    }, 4200);
  } else {
    cursor.style.display = 'none';
  }

  $$('[data-profile]').forEach((b) => b.addEventListener('click', () => {
    pausedUntil = Date.now() + 12000;
    switchTo(+b.dataset.profile, { hud: !!b.closest('.menu') });
  }));

  /* ---------- Scroll, folha ativa, reveal ---------- */
  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      ticking = false;
      $('#nav').classList.toggle('scrolled', scrollY > 20);
      updateA();
      updateB();
    });
  };
  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', onScroll);

  const sheets = $$('[data-sheet]');
  const total = sheets.length;
  const sheetIO = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      $('#tb-title').textContent = e.target.dataset.title;
      $('#tb-sheet').textContent = `${e.target.dataset.sheet}/${total}`;
    });
  }, { rootMargin: '-45% 0px -45% 0px' });
  sheets.forEach((s) => sheetIO.observe(s));

  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  $$('.reveal').forEach((el) => io.observe(el));
  if (reduced) $$('.reveal').forEach((el) => el.classList.add('in'));

  /* ---------- Abas, copiar, lista de espera ---------- */
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
    if (!input.checkValidity() || !input.value) { msg.textContent = 'Digite um e-mail válido.'; msg.style.color = '#ff8d86'; return; }
    msg.textContent = 'Anotado! Avisamos quando a versão Ubuntu sair.'; msg.style.color = 'var(--cy)';
    input.value = '';
  });
  $('#dl-mac')?.addEventListener('click', (e) => { if (e.currentTarget.getAttribute('href') === '#') e.preventDefault(); });

  /* ---------- Início ---------- */
  bind(0);
  updateA();
  updateB();
  // as fontes mudam a altura do texto: refaz as linhas quando terminarem de carregar
  document.fonts?.ready.then(() => { updateA(); });
})();
