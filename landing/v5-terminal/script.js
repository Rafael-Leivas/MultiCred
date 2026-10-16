(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;
  root.classList.add('js');

  const sleep = (ms) => new Promise((r) => setTimeout(r, reduced ? 0 : ms));

  // `term` is the CRT phosphor colour of the page; `color` is the real app badge colour.
  const PROFILES = [
    { id: 'trabalho', letter: 'N', color: '#5856D6', term: '#39ff88', name: 'Trabalho Acme', since: 'Ativo desde 09:12', email: 'ana@acme.dev', gh: 'ana-acme', claude: 'Claude · Acme', dir: '~/.claude-acme', needsLogin: false },
    { id: 'pessoal', letter: 'P', color: '#D9770B', term: '#ffb000', name: 'Pessoal', since: 'Ativo desde 14:33', email: 'ana.silva@gmail.com', gh: 'anasilva', claude: 'Claude · Pessoal', dir: '~/.claude-pessoal', needsLogin: false },
    { id: 'clientex', letter: 'X', color: '#0E8A9E', term: '#3de0f5', name: 'Cliente X', since: 'Ativo desde 16:05', email: 'ana@clientex.com', gh: 'ana-clientex', claude: 'Claude · Cliente X', dir: '~/.claude-clientex', needsLogin: true },
  ];
  const ALIASES = { trabalho: 0, work: 0, acme: 0, n: 0, pessoal: 1, personal: 1, p: 1, clientex: 2, cliente: 2, x: 2 };

  let current = -1;
  let hudTimer;
  let pausedUntil = 0;

  function setProfile(i, { hud = false } = {}) {
    if (i === current) return;
    const first = current === -1;
    current = i;
    const p = PROFILES[i];
    root.style.setProperty('--prof', p.color);
    root.style.setProperty('--g', p.term);
    $('meta[name="theme-color"]')?.setAttribute('content', '#020a05');
    $$('[data-bind]').forEach((el) => {
      const key = el.dataset.bind;
      if (key === 'badge') el.textContent = p.letter;
      else if (p[key] !== undefined && el.textContent !== p[key]) {
        el.textContent = p[key];
        if (!first) {
          const target = el.closest('.out') || el.closest('li');
          if (target) { target.classList.remove('flash'); void target.offsetWidth; target.classList.add('flash'); }
        }
      }
    });
    $$('.mi[data-profile]').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    $$('.tab').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    $('.mh-list')?.querySelectorAll('li').forEach((li) => { li.style.animation = 'none'; void li.offsetWidth; li.style.animation = ''; });

    if (hud && !reduced) {
      const h = $('#hud');
      h.classList.add('show');
      clearTimeout(hudTimer);
      hudTimer = setTimeout(() => h.classList.remove('show'), 1500);
    }
  }
  setProfile(0);

  // Mockup menu + demo terminal tabs.
  $$('.mi[data-profile], .tab[data-profile]').forEach((b) => b.addEventListener('click', () => {
    pausedUntil = Date.now() + 12000;
    setProfile(+b.dataset.profile, { hud: !!b.closest('.menu') });
  }));

  /* ---------- typing helpers ---------- */
  async function typeText(el, text, ms = 18) {
    if (reduced) { el.textContent = text; return; }
    el.textContent = '';
    for (const ch of text) { el.textContent += ch; await sleep(ms); }
  }

  /* ---------- interactive shell ---------- */
  const out = $('#out');
  const form = $('#prompt');
  const input = $('#cmd');
  const history = [];
  let hIdx = 0;
  let queue = Promise.resolve();

  function print(...segs) {
    const row = document.createElement('div');
    row.className = 'o';
    segs.forEach((s) => {
      const [text, cls] = Array.isArray(s) ? s : [s, ''];
      const sp = document.createElement('span');
      if (cls) sp.className = cls;
      sp.textContent = text;
      row.appendChild(sp);
    });
    out.appendChild(row);
    out.scrollTop = out.scrollHeight;
    return row;
  }
  const echo = (line) => print(['❯ ', 'pa'], [line, 'cm']);

  async function emit(lines, gap = 130) {
    for (const l of lines) { print(...l); await sleep(gap); }
  }

  async function exec(raw) {
    const line = raw.trim();
    if (!line) return;
    history.push(line); hIdx = history.length;
    echo(line);
    await sleep(120);

    const parts = line.toLowerCase().split(/\s+/);
    if (parts[0] === 'sudo') {
      await emit([
        [['ana não está no arquivo sudoers. ', 'er'], ['Este incidente será reportado.', 'er']],
        [['(brincadeira: o MultiCred não precisa de sudo.)', 'dm']],
      ]);
      return;
    }
    if (parts[0] === 'multicred') parts.shift();
    const c = parts[0] || 'help';

    if (c === 'clear' || c === 'cls') { out.innerHTML = ''; return; }

    if (c === 'help' || c === '--help' || c === '-h') {
      await emit([
        [['comandos:', 'dm']],
        [['  multicred switch <perfil>', 'ok'], ['   troca git, gh, claude e chaves', 'dm']],
        [['  status', 'ok'], ['                      mostra o perfil ativo', 'dm']],
        [['  install', 'ok'], ['                     vai para a instalação', 'dm']],
        [['  clear', 'ok'], ['                       limpa a tela', 'dm']],
        [['perfis: trabalho · pessoal · clientex', 'dm']],
      ], 70);
      return;
    }

    if (c === 'status') {
      const p = PROFILES[current];
      await emit([
        [['perfil ativo: ', 'dm'], [p.name, 'ok']],
        [['git     ', 'dm'], [p.email, '']],
        [['gh      ', 'dm'], [p.gh, '']],
        p.needsLogin ? [['claude  ', 'dm'], ['precisa entrar', 'wn']] : [['claude  ', 'dm'], [p.dir, '']],
      ], 90);
      return;
    }

    if (c === 'install') {
      await emit([[['→ macOS 14+ · rolando até a instalação…', 'ok']]], 200);
      pausedUntil = Date.now() + 8000;
      await sleep(450);
      $('#instalar')?.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth' });
      return;
    }

    let name = c;
    if (c === 'switch' || c === 'use' || c === 'troca' || c === 'trocar') name = parts.slice(1).join(' ');
    if (name === 'cliente x') name = 'clientex';
    const idx = Object.prototype.hasOwnProperty.call(ALIASES, name) ? ALIASES[name] : undefined;
    if (idx !== undefined) {
      const p = PROFILES[idx];
      pausedUntil = Date.now() + 15000;
      await emit([[[`→ aplicando perfil "${p.name}"…`, 'dm']]], 220);
      setProfile(idx, { hud: true });
      await emit([
        [['✓ ', 'ok'], ['git     ', 'dm'], [p.email, '']],
        [['✓ ', 'ok'], ['gh      ', 'dm'], [p.gh, '']],
        p.needsLogin ? [['⚠ ', 'wn'], ['claude  ', 'dm'], ['precisa entrar (login no navegador)', 'wn']] : [['✓ ', 'ok'], ['claude  ', 'dm'], [p.dir, '']],
        [['✓ ', 'ok'], ['pronto. abra um novo terminal.', '']],
      ], 170);
      return;
    }

    if (c === 'switch' || c === 'use') {
      await emit([[['uso: multicred switch <trabalho|pessoal|clientex>', 'wn']]]);
      return;
    }
    await emit([[[`command not found: ${parts[0]}. tente `, 'er'], ['help', 'ok']]]);
  }
  const run = (line) => { queue = queue.then(() => exec(line)).catch(() => {}); };

  form?.addEventListener('submit', (e) => { e.preventDefault(); const v = input.value; input.value = ''; run(v); });
  input?.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowUp' && history.length) { e.preventDefault(); hIdx = Math.max(0, hIdx - 1); input.value = history[hIdx] || ''; }
    else if (e.key === 'ArrowDown' && history.length) { e.preventDefault(); hIdx = Math.min(history.length, hIdx + 1); input.value = history[hIdx] || ''; }
  });
  $$('.chip').forEach((b) => b.addEventListener('click', () => run(b.dataset.cmd)));

  /* ---------- easter egg: Konami ---------- */
  const toast = $('#toast');
  function say(msg) {
    toast.textContent = msg; toast.classList.add('show');
    setTimeout(() => toast.classList.remove('show'), 3200);
  }
  const KONAMI = ['ArrowUp', 'ArrowUp', 'ArrowDown', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ArrowLeft', 'ArrowRight', 'b', 'a'];
  let kpos = 0;
  addEventListener('keydown', (e) => {
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    kpos = k === KONAMI[kpos] ? kpos + 1 : (k === KONAMI[0] ? 1 : 0);
    if (kpos === KONAMI.length) {
      kpos = 0;
      say('↑↑↓↓←→←→BA · modo festa desbloqueado');
      pausedUntil = Date.now() + 8000;
      const start = current;
      let n = 0;
      const t = setInterval(() => {
        setProfile((start + ++n) % PROFILES.length, { hud: false });
        if (n >= 9) { clearInterval(t); setProfile(start); }
      }, reduced ? 50 : 320);
    }
  });

  /* ---------- hero: boot + typed headline ---------- */
  const desk = $('#desk');
  const cursor = $('#cursor');
  let heroVisible = true;
  new IntersectionObserver(([e]) => (heroVisible = e.isIntersecting), { threshold: 0.3 }).observe(desk);

  function glideTo(i) {
    const item = $$('.mi[data-profile]')[i];
    const d = desk.getBoundingClientRect();
    const r = item.getBoundingClientRect();
    cursor.style.left = `${r.left - d.left + r.width * 0.45}px`;
    cursor.style.top = `${r.top - d.top + r.height * 0.4}px`;
  }
  function autoplay() {
    if (!heroVisible || Date.now() < pausedUntil) return;
    const next = (current + 1) % PROFILES.length;
    glideTo(next);
    setTimeout(() => {
      cursor.classList.add('click');
      setProfile(next, { hud: true });
      setTimeout(() => cursor.classList.remove('click'), 350);
    }, 1050);
  }

  async function intro() {
    const lines = $$('#boot .b');
    const spans = $$('#h1 [data-t]');
    const caret = $('#h1c');
    if (!reduced) {
      spans.forEach((s) => (s.textContent = ''));
      caret.style.display = 'none';
    }
    for (const l of lines) { l.classList.add('on'); await sleep(150); }
    await sleep(250);
    caret.style.display = '';
    for (const s of spans) await typeText(s, s.dataset.t, 30);
    await sleep(300);
    caret.style.display = 'none';
    $$('.after').forEach((el, i) => setTimeout(() => el.classList.add('on'), reduced ? 0 : i * 170));
    if (!reduced) {
      cursor.style.display = '';
      setTimeout(() => { glideTo(0); setInterval(autoplay, 4200); }, 900);
    }
  }
  if (reduced) cursor.style.display = 'none';
  intro();

  /* ---------- per-block reveal: typed command + staggered lines ---------- */
  $$('.blk').forEach((b) => $$('.ln', b).forEach((el, i) => el.style.setProperty('--i', Math.min(i, 12))));
  if (!reduced) $$('.cmd .t').forEach((t) => { t.dataset.t = t.dataset.t || t.textContent; t.textContent = ''; });

  const blockIO = new IntersectionObserver((entries) => {
    entries.forEach(async (e) => {
      if (!e.isIntersecting) return;
      blockIO.unobserve(e.target);
      const cmd = $('.cmd', e.target);
      const t = cmd && $('.t', cmd);
      if (t && !reduced) {
        cmd.classList.add('typing');
        await typeText(t, t.dataset.t, 22);
        cmd.classList.remove('typing');
      }
      e.target.classList.add('in');
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  $$('.blk').forEach((b) => blockIO.observe(b));
  $('.final') && blockIO.observe($('.final'));

  /* ---------- nav shadow ---------- */
  const nav = $('#nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 20);
  onScroll(); addEventListener('scroll', onScroll, { passive: true });

  /* ---------- count-up ---------- */
  const cio = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      cio.unobserve(e.target);
      const end = +e.target.dataset.count;
      if (reduced || end === 0) { e.target.textContent = end; return; }
      const t0 = performance.now();
      const tick = (t) => {
        const k = Math.min((t - t0) / 1400, 1);
        e.target.textContent = Math.round(end * (1 - Math.pow(1 - k, 3)));
        if (k < 1) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
  }, { threshold: 0.6 });
  $$('[data-count]').forEach((el) => cio.observe(el));

  /* ---------- tilt on screenshots ---------- */
  if (!reduced && matchMedia('(hover: hover)').matches) {
    $$('.tilt').forEach((el) => {
      el.addEventListener('pointermove', (e) => {
        const r = el.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width - 0.5;
        const y = (e.clientY - r.top) / r.height - 0.5;
        el.style.transform = `perspective(1100px) rotateY(${x * 6}deg) rotateX(${-y * 6}deg) translateY(-3px)`;
      });
      el.addEventListener('pointerleave', () => { el.style.transform = ''; });
    });
  }

  /* ---------- OS tabs / copy / waitlist ---------- */
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
    const field = e.target.querySelector('input');
    const msg = $('#wait-msg');
    if (!field.checkValidity() || !field.value) { msg.textContent = 'Digite um e-mail válido.'; msg.style.color = 'var(--bad)'; return; }
    msg.textContent = 'Anotado! Avisamos quando a versão Ubuntu sair.'; msg.style.color = 'var(--g)';
    field.value = '';
  });
  $('#dl-mac')?.addEventListener('click', (e) => { if (e.currentTarget.getAttribute('href') === '#') e.preventDefault(); });
})();
