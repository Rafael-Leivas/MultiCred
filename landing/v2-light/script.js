(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const PROFILES = [
    { letter: 'N', color: '#5856D6', name: 'Trabalho Acme', since: 'Ativo desde 09:12', email: 'ana@acme.dev', gh: 'ana-acme', claude: 'Claude · Acme', dir: '~/.claude-acme' },
    { letter: 'P', color: '#D9770B', name: 'Pessoal', since: 'Ativo desde 14:33', email: 'ana.silva@gmail.com', gh: 'anasilva', claude: 'Claude · Pessoal', dir: '~/.claude-pessoal' },
    { letter: 'X', color: '#0E8A9E', name: 'Cliente X', since: 'Ativo desde 16:05', email: 'ana@clientex.com', gh: 'ana-clientex', claude: 'Claude · Cliente X', dir: '~/.claude-clientex' },
  ];

  let current = -1;
  let hudTimer;

  function setProfile(i, { hud = false } = {}) {
    if (i === current) return;
    const first = current === -1;
    current = i;
    const p = PROFILES[i];
    document.documentElement.style.setProperty('--prof', p.color);
    $$('[data-bind]').forEach((el) => {
      const key = el.dataset.bind;
      if (key === 'badge') el.textContent = p.letter;
      else if (key === 'badge-bg') return;
      else if (p[key] !== undefined && el.textContent !== p[key]) {
        el.textContent = p[key];
        if (!first) {
          const row = el.closest('.out');
          const target = row || el.closest('li');
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

  // Manual clicks (menu + terminal tabs) pause the autoplay for a while.
  let pausedUntil = 0;
  $$('[data-profile]').forEach((b) => b.addEventListener('click', () => {
    pausedUntil = Date.now() + 12000;
    setProfile(+b.dataset.profile, { hud: !!b.closest('.menu') });
  }));

  // Hero autoplay: cursor glides to the next profile, clicks, HUD pops.
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
  if (!reduced) {
    setTimeout(() => { glideTo(0); setInterval(loop, 4200); }, 1400);
  } else {
    cursor.style.display = 'none';
  }

  // Nav shadow
  const nav = $('#nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 20);
  onScroll(); addEventListener('scroll', onScroll, { passive: true });

  // Reveal on scroll
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

  // Card spotlight
  $$('.spot').forEach((c) => c.addEventListener('pointermove', (e) => {
    const r = c.getBoundingClientRect();
    c.style.setProperty('--mx', `${e.clientX - r.left}px`);
    c.style.setProperty('--my', `${e.clientY - r.top}px`);
  }));

  // Tilt on screenshots
  if (!reduced && matchMedia('(hover: hover)').matches) {
    $$('.tilt').forEach((el) => {
      el.addEventListener('pointermove', (e) => {
        if (!el.classList.contains('in')) return;
        const r = el.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width - 0.5;
        const y = (e.clientY - r.top) / r.height - 0.5;
        el.style.transform = `perspective(1100px) rotateY(${x * 7}deg) rotateX(${-y * 7}deg) translateY(-4px)`;
      });
      el.addEventListener('pointerleave', () => { el.style.transform = ''; });
    });
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
    if (!input.checkValidity() || !input.value) { msg.textContent = 'Digite um e-mail válido.'; msg.style.color = 'var(--red)'; return; }
    msg.textContent = 'Anotado! Avisamos quando a versão Ubuntu sair.'; msg.style.color = 'var(--green)';
    input.value = '';
  });
  $('#dl-mac')?.addEventListener('click', (e) => { if (e.currentTarget.getAttribute('href') === '#') e.preventDefault(); });
})();
