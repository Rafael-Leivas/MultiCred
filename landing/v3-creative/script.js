(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;

  // `page` is the darkened background (white text stays readable); `color` is the true profile color.
  const PROFILES = [
    { letter: 'N', color: '#5856D6', page: '#5856D6', word: 'Trabalho', name: 'Trabalho Acme', since: 'Ativo desde 09:12', email: 'ana@acme.dev', gh: 'ana-acme', claude: 'Claude · Acme', dir: '~/.claude-acme' },
    { letter: 'P', color: '#D9770B', page: '#BF4A0A', word: 'Pessoal', name: 'Pessoal', since: 'Ativo desde 14:33', email: 'ana.silva@gmail.com', gh: 'anasilva', claude: 'Claude · Pessoal', dir: '~/.claude-pessoal' },
    { letter: 'X', color: '#0E8A9E', page: '#0B7285', word: 'Cliente X', name: 'Cliente X', since: 'Ativo desde 16:05', email: 'ana@clientex.com', gh: 'ana-clientex', claude: 'Claude · Cliente X', dir: '~/.claude-clientex' },
  ];

  let current = -1;
  let hudTimer;
  const themeMeta = $('meta[name="theme-color"]');

  function restart(el, cls) { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); }

  function setProfile(i, { hud = false } = {}) {
    if (i === current) return;
    const first = current === -1;
    current = i;
    const p = PROFILES[i];
    root.style.setProperty('--prof', p.page);
    root.style.setProperty('--pc', p.color);
    themeMeta?.setAttribute('content', p.page);

    $$('[data-bind]').forEach((el) => {
      const key = el.dataset.bind;
      const value = key === 'badge' ? p.letter : p[key];
      if (value === undefined || el.textContent === value) return;
      el.textContent = value;
      if (first) return;
      if (key === 'word') restart(el, 'swap');
      else if (key !== 'badge') {
        const target = el.closest('.out') || el.closest('li');
        if (target) restart(target, target.classList.contains('out') ? 'flash' : 'swap');
      }
    });
    $$('.mi[data-profile]').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    $$('.tab').forEach((b) => b.classList.toggle('on', +b.dataset.profile === i));
    $$('.mh-list li').forEach((li) => { li.style.animation = 'none'; void li.offsetWidth; li.style.animation = ''; });

    if (hud && !reduced) {
      const h = $('#hud');
      h.classList.add('show');
      clearTimeout(hudTimer);
      hudTimer = setTimeout(() => h.classList.remove('show'), 1500);
    }
  }
  setProfile(0);

  // Manual picks pause the autoplay for a while.
  let pausedUntil = 0;
  const pause = (ms = 12000) => { pausedUntil = Date.now() + ms; };
  $$('[data-profile]').forEach((b) => b.addEventListener('click', () => {
    pause();
    setProfile(+b.dataset.profile, { hud: !!b.closest('.menu') });
  }));
  $('#lanyard')?.addEventListener('click', () => {
    pause();
    setProfile((current + 1) % PROFILES.length, { hud: true });
  });

  // Hero autoplay: the fake cursor clicks the next profile.
  const desk = $('#desk');
  const cursor = $('#cursor');
  let heroVisible = true;
  new IntersectionObserver(([e]) => (heroVisible = e.isIntersecting), { threshold: 0.3 }).observe(desk);

  function glideTo(i) {
    const item = $$('.mi[data-profile]')[i];
    // offsetLeft/Top are layout-based, so the desk's rotation does not skew them.
    let x = 0, y = 0, el = item;
    while (el && el !== desk) { x += el.offsetLeft; y += el.offsetTop; el = el.offsetParent; }
    cursor.style.left = `${x + item.offsetWidth * 0.45}px`;
    cursor.style.top = `${y + item.offsetHeight * 0.4}px`;
  }
  function loop() {
    if (!heroVisible || Date.now() < pausedUntil) return;
    const next = (current + 1) % PROFILES.length;
    glideTo(next);
    setTimeout(() => {
      cursor.classList.add('click');
      setProfile(next, { hud: true });
      setTimeout(() => cursor.classList.remove('click'), 350);
    }, 1050);
  }
  if (!reduced) setTimeout(() => { glideTo(0); setInterval(loop, 4200); }, 1400);
  else cursor.style.display = 'none';

  // Scroll-linked: marquee offset, progress bar, nav auto-hide.
  const progress = $('#progress');
  const nav = $('#nav');
  let lastY = scrollY, ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      const y = scrollY;
      const max = document.documentElement.scrollHeight - innerHeight;
      progress.style.transform = `scaleX(${max > 0 ? y / max : 0})`;
      if (!reduced) root.style.setProperty('--sy', y.toFixed(0));
      nav.classList.toggle('hide', y > 400 && y > lastY + 4);
      if (y < lastY - 4) nav.classList.remove('hide');
      lastY = y;
      ticking = false;
    });
  }
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // Marquee rows: clone the set so the scroll offset never runs out.
  $$('.row').forEach((row) => {
    const set = [...row.children];
    for (let n = 0; n < 3; n++) set.forEach((s) => { const c = s.cloneNode(true); c.setAttribute('aria-hidden', 'true'); row.appendChild(c); });
  });

  // Reveal
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  $$('.reveal').forEach((el) => io.observe(el));

  // Count-up
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

  // Steps: the step in the middle of the screen drives the profile (and the page color).
  const steps = $$('.step');
  const sio = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      steps.forEach((s) => s.classList.toggle('active', s === e.target));
      if (Date.now() >= pausedUntil) setProfile(+e.target.dataset.step);
    });
  }, { rootMargin: '-42% 0px -42% 0px' });
  steps.forEach((s) => sio.observe(s));

  // Cursor ring (pointer devices only)
  const ring = $('#ring');
  if (!reduced && matchMedia('(hover: hover)').matches) {
    let tx = 0, ty = 0, x = 0, y = 0;
    addEventListener('pointermove', (e) => { tx = e.clientX; ty = e.clientY; ring.classList.add('on'); });
    document.addEventListener('pointerleave', () => ring.classList.remove('on'));
    (function frame() {
      x += (tx - x) * 0.22; y += (ty - y) * 0.22;
      ring.style.transform = `translate(${x}px, ${y}px)`;
      requestAnimationFrame(frame);
    })();
    document.addEventListener('pointerover', (e) => ring.classList.toggle('big', !!e.target.closest('a, button, summary, input')));
  }

  // OS tabs
  $$('.os').forEach((b) => b.addEventListener('click', () => {
    $$('.os').forEach((o) => { o.classList.toggle('on', o === b); o.setAttribute('aria-selected', o === b); });
    $$('.os-panel').forEach((p) => p.classList.toggle('on', p.id === `os-${b.dataset.os}`));
  }));

  // Copy buttons
  $$('.copy').forEach((b) => b.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(b.parentElement.dataset.copy); } catch { /* clipboard blocked */ }
    b.textContent = 'Copiado ✓'; b.classList.add('done');
    setTimeout(() => { b.textContent = 'Copiar'; b.classList.remove('done'); }, 1800);
  }));

  // Waitlist (UI only until a backend exists)
  $('#wait')?.addEventListener('submit', (e) => {
    e.preventDefault();
    const input = e.target.querySelector('input');
    const msg = $('#wait-msg');
    if (!input.checkValidity() || !input.value) { msg.textContent = 'Digite um e-mail válido.'; msg.style.color = '#c8101e'; return; }
    msg.textContent = 'Anotado! Avisamos quando a versão Ubuntu sair.'; msg.style.color = '#1c8a36';
    input.value = '';
  });
  $('#dl-mac')?.addEventListener('click', (e) => { if (e.currentTarget.getAttribute('href') === '#') e.preventDefault(); });
})();
