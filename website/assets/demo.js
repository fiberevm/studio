// Hero demo: one Studio window that builds itself up, VS Code–site style.
// 1) a Claude session  2) split, second session  3) a browser panel  4) a terminal. Then it loops.
(() => {
  const stage = document.getElementById("demo");
  if (!stage) return;
  const win = stage.querySelector(".dw");
  const $ = (s) => win.querySelector(s);
  const steps = [...document.querySelectorAll("#demo-steps li")];
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Scale the fixed-size window to the stage width.
  const W = 1160, H = 720;
  const fit = () => { win.style.transform = `scale(${stage.clientWidth / W})`; stage.style.height = (H * stage.clientWidth / W) + "px"; };
  new ResizeObserver(fit).observe(stage); fit();

  let run = 0;            // bumping this cancels the running timeline
  let instant = false;    // reduced motion: render the end state without waiting
  const sleep = (ms, id) => new Promise((res, rej) => {
    if (instant) return res();
    setTimeout(() => (id === run ? res() : rej("cancel")), ms);
  });

  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  function el(tag, cls, html) { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }

  async function type(target, text, id, speed = 26) {
    if (instant) { target.textContent += text; return; }
    for (const ch of text) { target.textContent += ch; await sleep(speed + (ch === " " ? 10 : Math.random() * 18), id); }
  }

  function setStatus(pane, kind) { const s = pane.querySelector(".tab.on .st"); s.className = "st " + kind; }
  function setTitle(pane, t) { pane.querySelector(".tab.on .tt").textContent = t; }

  // A Claude Code–style session: header, transcript, input box.
  function claude(pane, cwd) {
    const body = pane.querySelector(".body");
    body.innerHTML = "";
    body.append(el("div", "cc-head", `<span class="cc-logo">✻</span> <b>Claude Code</b><br><span class="dim">${cwd}</span>`));
    const log = el("div", "cc-log"); body.append(log);
    // Stay pinned to the newest line, also while the pane shrinks during a split.
    new ResizeObserver(() => { log.scrollTop = 1e6; }).observe(log);
    const box = el("div", "cc-input", `<span class="pr">›</span> <span class="txt"></span><span class="cur"></span>`);
    body.append(box, el("div", "cc-hint", "⏵⏵ auto-accept edits on"));
    return {
      async ask(text, id) {
        const t = box.querySelector(".txt"); t.textContent = "";
        await type(t, text, id); await sleep(380, id);
        t.textContent = "";
        log.append(el("div", "cc-you", "› " + esc(text)));
        log.scrollTop = 1e6;
      },
      line(html, cls = "cc-a") { const d = el("div", cls, html); log.append(d); log.scrollTop = 1e6; return d; },
      tool(name, arg, result) {
        const d = this.line(`<span class="dot g">●</span> <b>${name}</b>(<span class="dim">${esc(arg)}</span>)`);
        if (result) d.append(el("div", "cc-res", "⎿ " + result));
        return d;
      },
      say(html) { return this.line(`<span class="dot">●</span> ${html}`); },
      thinking(on) {
        let t = log.querySelector(".cc-think");
        if (on && !t) { t = el("div", "cc-think", `<span class="spin">✻</span> Thinking…`); log.append(t); }
        if (!on && t) t.remove();
      },
    };
  }

  function reset() {
    win.classList.remove("s2", "s3", "s4");
    for (const b of win.querySelectorAll(".pane .body")) b.innerHTML = "";
    setTitle($("#pA"), "New session"); setStatus($("#pA"), "");
    setTitle($("#pB"), "New session"); setStatus($("#pB"), "");
    $("#pW .page").classList.remove("on"); $("#pW .addr").textContent = "";
    steps.forEach((s) => s.classList.remove("on", "done"));
  }
  function step(i) { steps.forEach((s, j) => { s.classList.toggle("on", j === i); s.classList.toggle("done", j < i); }); }

  async function timeline(id) {
    reset(); await sleep(700, id);

    // 1 — a Claude session
    step(0);
    const A = claude($("#pA"), "~/code/acme");
    await sleep(600, id);
    await A.ask("the auth spec fails on CI about 1 in 5 runs — find out why and fix it", id);
    setTitle($("#pA"), "Fix flaky auth spec"); setStatus($("#pA"), "work");
    A.thinking(true); await sleep(1300, id); A.thinking(false);
    A.tool("Read", "spec/auth_spec.ts, src/session.ts"); await sleep(700, id);
    A.tool("Bash", "npm test -- auth --repeat 20", "4 failed · token expired before assertion"); await sleep(1100, id);
    A.say("The session token has a 1s TTL and the test waits on a real clock. I'll freeze time in the spec.");
    await sleep(900, id);

    // 2 — split, a second session
    step(1);
    win.classList.add("s2"); await sleep(800, id);
    const B = claude($("#pB"), "~/code/acme");
    await sleep(500, id);
    A.tool("Update", "spec/auth_spec.ts", "<span class='add'>+4</span> <span class='del'>−2</span>");
    await B.ask("build the new checkout summary card and run the dev server", id);
    setTitle($("#pB"), "Checkout summary card"); setStatus($("#pB"), "work");
    B.thinking(true); await sleep(1000, id); B.thinking(false);
    B.tool("Write", "app/checkout/Summary.tsx", "62 lines");
    A.tool("Bash", "npm test -- auth --repeat 50", "<span class='ok'>50 passed</span>"); await sleep(700, id);
    const ask = B.line(`<div class="cc-perm"><b>Allow</b> Bash(npm run dev)?<div><span class="sel">› 1. Yes</span>  2. No</div></div>`);
    setStatus($("#pB"), "need");
    A.say("Fixed: the spec now uses a fake clock. 50 runs in a row are green."); setStatus($("#pA"), "done");
    await sleep(1700, id);
    ask.remove(); setStatus($("#pB"), "work");
    B.tool("Bash", "npm run dev", "ready on http://localhost:3000"); await sleep(700, id);
    B.tool("studio · open_url", "localhost:3000/checkout"); await sleep(500, id);

    // 3 — a browser panel
    step(2);
    win.classList.add("s3"); await sleep(700, id);
    setTitle($("#pW"), "Checkout · localhost");
    await type($("#pW .addr"), "localhost:3000/checkout", id, 14);
    await sleep(300, id);
    $("#pW .page").classList.add("on"); await sleep(1000, id);
    B.say("The summary card is live in the panel beside you."); setStatus($("#pB"), "done");
    await sleep(1200, id);

    // 4 — a terminal
    step(3);
    win.classList.add("s4"); await sleep(700, id);
    const T = $("#pT .body"); T.innerHTML = "";
    const cmd = async (c, out) => {
      const l = el("div", "t-l", `<span class="t-p">~/code/acme $</span> <span class="t-c"></span>`); T.append(l);
      await type(l.querySelector(".t-c"), c, id, 30); await sleep(350, id);
      for (const o of out) { T.append(el("div", "t-o", o)); await sleep(120, id); }
    };
    await cmd("git status --short", [" <span class='t-m'>M</span> spec/auth_spec.ts", " <span class='t-a'>A</span> app/checkout/Summary.tsx"]);
    await sleep(500, id);
    await cmd("gh pr create --fill", ["<span class='dim'>Creating pull request for fix-flaky-auth…</span>", "https://github.com/acme/web/pull/482"]);
    T.append(el("div", "t-l", `<span class="t-p">~/code/acme $</span> <span class="cur"></span>`));
    steps.forEach((s) => { s.classList.remove("on"); s.classList.add("done"); });
    await sleep(5200, id);
  }

  async function loop() {
    for (;;) {
      const id = ++run;
      try { await timeline(id); } catch (e) { if (e !== "cancel") console.error(e); return; }
      win.classList.add("fade"); await new Promise((r) => setTimeout(r, 450)); win.classList.remove("fade");
    }
  }

  if (reduce) { instant = true; timeline(++run); return; }
  // Start when visible; pause (restart later) when the tab is hidden.
  document.addEventListener("visibilitychange", () => { if (document.hidden) run++; else loop(); });
  loop();
})();
