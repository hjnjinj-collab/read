/* 首页 Dashboard 布局稿逻辑 */
(function () {
  const books = [
    { name: "雪中悍刀行", author: "烽火戏诸侯", ch: "第 128 章 · 风雪夜归人", pct: 42, c: "c1" },
    { name: "诡秘之主", author: "爱潜水的乌贼", ch: "第 56 章", pct: 18, c: "c2" },
    { name: "大奉打更人", author: "卖报小郎君", ch: "第 210 章", pct: 67, c: "c3" },
    { name: "夜的命名术", author: "会说话的肘子", ch: "第 33 章", pct: 9, c: "c4" },
    { name: "道诡异仙", author: "狐尾的笔", ch: "第 88 章", pct: 51, c: "c1" },
    { name: "深海余烬", author: "远瞳", ch: "第 12 章", pct: 5, c: "c3" },
  ];

  /** 演示：常规 vs 空数据 */
  let demoRich = true;

  const days = ["一", "二", "三", "四", "五", "六", "日"];
  const richMin = [12, 28, 8, 35, 22, 41, 18];
  const emptyMin = [0, 0, 0, 0, 0, 0, 0];

  const $ = (id) => document.getElementById(id);

  function drawChart(values) {
    const svg = $("chart");
    const labels = $("chartLabels");
    const w = 320, h = 120, padX = 8, padY = 12;
    const max = Math.max(10, ...values);
    const n = values.length;
    const stepX = (w - padX * 2) / (n - 1);
    const pts = values.map((v, i) => {
      const x = padX + i * stepX;
      const y = h - padY - (v / max) * (h - padY * 2);
      return [x, y];
    });
    const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + "," + p[1].toFixed(1)).join(" ");
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
    const sum = values.reduce((a, b) => a + b, 0);
    $("weekSum").textContent = String(sum);
  }

  function renderRecent() {
    const row = $("recentRow");
    row.innerHTML = books
      .slice(0, 5)
      .map(
        (b) => `
      <div class="hcard">
        <div class="cover ${b.c}"></div>
        <div class="n">${b.name}</div>
      </div>`
      )
      .join("");
  }

  function renderShelf() {
    const grid = $("shelfGrid");
    grid.innerHTML = books
      .map(
        (b) => `
      <div class="gitem">
        <div class="cover ${b.c}"></div>
        <div class="n">${b.name}</div>
        <div class="p">${b.pct}%</div>
      </div>`
      )
      .join("");
  }

  function renderHero() {
    const b = books[0];
    $("heroName").textContent = b.name;
    $("heroAuthor").textContent = b.author;
    $("heroChapter").textContent = b.ch;
    $("heroPct").textContent = b.pct + "%";
    $("heroFill").style.width = b.pct + "%";
    const cover = $("heroCover");
    cover.className = "cover " + b.c;
  }

  function renderGoal() {
    const todayMin = demoRich ? 18 : 0;
    const goal = 30;
    const ratio = goal ? todayMin / goal : 0;
    $("goalText").textContent = `${todayMin} / ${goal} 分钟`;
    $("goalPct").textContent = Math.round(ratio * 100) + "%";
    const circ = 2 * Math.PI * 32;
    const ring = $("goalRing");
    ring.style.strokeDasharray = String(circ);
    ring.style.strokeDashoffset = String(circ * (1 - ratio));
  }

  function applyDemo() {
    const values = demoRich ? richMin : emptyMin;
    drawChart(values);
    if (!demoRich) {
      $("heroName").textContent = "暂无最近阅读";
      $("heroAuthor").textContent = "导入书籍后将出现在这里";
      $("heroChapter").textContent = "";
      $("heroPct").textContent = "—";
      $("heroFill").style.width = "0%";
    } else {
      renderHero();
    }
    renderGoal();
  }

  function switchTab(tab) {
    const map = { home: "首页", shelf: "书架", sources: "书源", settings: "设置" };
    document.querySelectorAll(".tab").forEach((t) => {
      t.classList.toggle("on", t.dataset.tab === tab);
    });
    document.querySelectorAll(".page").forEach((p) => {
      p.classList.toggle("on", p.dataset.page === tab);
    });
    $("pageTitle").textContent = map[tab] || "首页";
  }

  document.querySelectorAll(".tab").forEach((t) => {
    if (t.disabled) return;
    t.addEventListener("click", () => switchTab(t.dataset.tab));
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
