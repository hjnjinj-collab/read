/* 首页 Dashboard 布局稿 — 模块顺序定稿版 */
(function () {
  const books = [
    { name: "雪中悍刀行", author: "烽火戏诸侯", ch: "第 128 章 · 风雪夜归人", pct: 42, c: "c1" },
    { name: "诡秘之主", author: "爱潜水的乌贼", ch: "第 56 章", pct: 18, c: "c2" },
    { name: "大奉打更人", author: "卖报小郎君", ch: "第 210 章", pct: 67, c: "c3" },
    { name: "夜的命名术", author: "会说话的肘子", ch: "第 33 章", pct: 9, c: "c4" },
    { name: "道诡异仙", author: "狐尾的笔", ch: "第 88 章", pct: 51, c: "c1" },
    { name: "深海余烬", author: "远瞳", ch: "第 12 章", pct: 5, c: "c3" },
  ];
  const days = ["一", "二", "三", "四", "五", "六", "日"];
  const richMin = [12, 28, 8, 35, 22, 41, 18];
  const emptyMin = [0, 0, 0, 0, 0, 0, 0];
  let demoRich = true;
  let heroIndex = 0;
  let heroTimer = null;

  const $ = (id) => document.getElementById(id);

  /** Hero 轮换：[0] 永远今日目标，其后为续读卡 */
  function heroSlides() {
    const goal = {
      type: "goal",
      badge: "今日目标",
      today: demoRich ? 18 : 0,
      target: 30,
    };
    const cont = books.slice(0, 2).map((b) => ({
      type: "continue",
      badge: "继续阅读",
      book: b,
    }));
    return [goal, ...cont];
  }

  function renderHero() {
    const slides = heroSlides();
    if (heroIndex >= slides.length) heroIndex = 0;
    const s = slides[heroIndex];
    $("heroBadge").textContent = s.badge;
    $("heroDots").innerHTML = slides
      .map((_, i) => `<i class="${i === heroIndex ? "on" : ""}"></i>`)
      .join("");
    const host = $("heroSlide");
    if (s.type === "goal") {
      const ratio = s.target ? s.today / s.target : 0;
      const circ = 2 * Math.PI * 32;
      host.innerHTML = `
        <div class="slide slide-goal">
          <svg class="ring" viewBox="0 0 80 80">
            <circle class="ring-bg" cx="40" cy="40" r="32"/>
            <circle class="ring-fg" cx="40" cy="40" r="32"
              style="stroke-dasharray:${circ};stroke-dashoffset:${circ * (1 - ratio)}"/>
          </svg>
          <div class="goal-side">
            <div class="goal-big">${s.today}<small style="font-size:14px;color:var(--muted)">/${s.target} 分钟</small></div>
            <div class="sec-sub">今日阅读目标 · ${Math.round(ratio * 100)}%</div>
            <button type="button" class="chip-btn">调整目标</button>
          </div>
        </div>`;
    } else {
      const b = s.book;
      host.innerHTML = `
        <div class="slide">
          <div class="poster-row" style="margin:0 -14px;padding:12px 14px;min-height:100px;border-radius:0;position:relative;overflow:hidden">
            <div style="position:absolute;inset:0;background:
              linear-gradient(90deg,rgba(0,0,0,0.55),rgba(0,0,0,0.2) 60%,transparent),
              linear-gradient(145deg,#2a4a3a,#1a3028 45%,#3a5068)"></div>
            <div class="cover ${b.c}" style="position:relative;box-shadow:0 3px 10px rgba(0,0,0,0.4)"></div>
            <div class="poster-meta" style="position:relative">
              <div class="badge">继续阅读</div>
              <div class="name">${b.name}</div>
              <div class="ch">${b.ch}</div>
              <div class="pbar"><i style="width:${b.pct}%"></i></div>
            </div>
            <button type="button" class="poster-cta" style="position:relative">继续</button>
          </div>
        </div>`;
    }
  }

  function armHero() {
    clearInterval(heroTimer);
    heroTimer = setInterval(() => {
      const n = heroSlides().length;
      heroIndex = (heroIndex + 1) % n;
      renderHero();
    }, 4000);
  }

  function drawChart(values) {
    const svg = $("chart");
    const labels = $("chartLabels");
    const w = 320, h = 120, padX = 8, padY = 12;
    const max = Math.max(10, ...values);
    const n = values.length;
    const stepX = (w - padX * 2) / (n - 1);
    const pts = values.map((v, i) => [
      padX + i * stepX,
      h - padY - (v / max) * (h - padY * 2),
    ]);
    const line = pts
      .map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + "," + p[1].toFixed(1))
      .join(" ");
    const area =
      line +
      ` L${pts[pts.length - 1][0].toFixed(1)},${h - 4} L${pts[0][0].toFixed(1)},${h - 4} Z`;
    const today = n - 1;
    let dots = "";
    pts.forEach((p, i) => {
      const r = i === today ? 4.5 : 3;
      const fill = i === today ? "#5d9b7e" : "rgba(93,155,126,0.55)";
      dots += `<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="${r}" fill="${fill}"/>`;
      if (i === today) {
        dots += `<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="8" fill="rgba(93,155,126,0.2)"/>`;
      }
    });
    const allZero = values.every((v) => v === 0);
    svg.innerHTML = `
      <defs>
        <linearGradient id="areaGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#5d9b7e" stop-opacity="0.35"/>
          <stop offset="100%" stop-color="#5d9b7e" stop-opacity="0"/>
        </linearGradient>
      </defs>
      <line x1="${padX}" y1="${h - 4}" x2="${w - padX}" y2="${h - 4}" stroke="rgba(255,255,255,0.08)" stroke-dasharray="4 4"/>
      ${allZero ? "" : `<path d="${area}" fill="url(#areaGrad)"/>`}
      ${allZero ? "" : `<path d="${line}" fill="none" stroke="#5d9b7e" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>`}
      ${dots}
      ${allZero ? `<text x="${w / 2}" y="${h / 2}" text-anchor="middle" fill="#8f9ea3" font-size="12">暂无阅读记录</text>` : ""}
    `;
    labels.innerHTML = days
      .map((d, i) => `<span class="${i === today ? "on" : ""}">${d}</span>`)
      .join("");
    $("weekSum").textContent = String(values.reduce((a, b) => a + b, 0));
  }

  function renderRecent() {
    $("recentRow").innerHTML = books
      .slice(0, 5)
      .map(
        (b) =>
          `<div class="hcard"><div class="cover ${b.c}"></div><div class="n">${b.name}</div></div>`
      )
      .join("");
  }

  function renderShelf() {
    $("shelfGrid").innerHTML = books
      .map(
        (b) =>
          `<div class="gitem"><div class="cover ${b.c}"></div><div class="n">${b.name}</div><div class="p">${b.pct}%</div></div>`
      )
      .join("");
  }

  function applyDemo() {
    heroIndex = 0; // 进入首页永远从今日目标起
    drawChart(demoRich ? richMin : emptyMin);
    renderHero();
    armHero();
  }

  document.querySelectorAll(".tab").forEach((t) => {
    if (t.disabled) return;
    t.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((x) => x.classList.remove("on"));
      t.classList.add("on");
      document.querySelectorAll(".page").forEach((p) => {
        p.classList.toggle("on", p.dataset.page === t.dataset.tab);
      });
      $("pageTitle").textContent =
        { home: "首页", shelf: "书架" }[t.dataset.tab] || "首页";
      if (t.dataset.tab === "home") {
        heroIndex = 0;
        renderHero();
        armHero();
      }
    });
  });

  $("modeBtn").addEventListener("click", () => {
    demoRich = !demoRich;
    $("modeBtn").textContent = demoRich ? "演示数据" : "空数据";
    applyDemo();
  });

  renderRecent();
  renderShelf();
  applyDemo();
})();
