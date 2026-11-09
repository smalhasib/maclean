(() => {
  const repo = "smalhasib/maclean";

  // Install tabs
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  const show = (tab) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute("aria-selected", on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
  };
  tabs.forEach((t, i) => {
    t.addEventListener("click", () => show(t));
    t.addEventListener("keydown", (e) => {
      const next = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!next) return;
      const to = tabs[(i + next + tabs.length) % tabs.length];
      show(to);
      to.focus();
    });
  });

  // Links that point at an install method open its tab first (the Homebrew chip in the hero).
  document.querySelectorAll("[data-tab]").forEach((link) => {
    link.addEventListener("click", () => show(document.getElementById(link.dataset.tab)));
  });

  // Copy buttons
  document.addEventListener("click", async (e) => {
    const el = e.target.closest("[data-copy]");
    if (!el) return;
    const label = el.querySelector(".copy-hint") || el;
    const before = label.textContent;
    try {
      await navigator.clipboard.writeText(el.dataset.copy);
      label.textContent = "Copied";
    } catch {
      label.textContent = "Press ⌘C";
    }
    setTimeout(() => (label.textContent = before), 1600);
  });

  // Scroll reveal
  const items = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => {
        if (!en.isIntersecting) return;
        en.target.classList.add("in");
        io.unobserve(en.target);
      });
    }, { threshold: 0.12 });
    items.forEach((el) => io.observe(el));
  } else {
    items.forEach((el) => el.classList.add("in"));
  }

  // Live release and star count from GitHub. The static links still work if this fails.
  const get = (path) => fetch(`https://api.github.com/repos/${repo}${path}`).then((r) => (r.ok ? r.json() : Promise.reject()));

  get("/releases/latest").then((rel) => {
    const dmg = rel.assets.find((a) => a.name.endsWith(".dmg"));
    if (!dmg) return;
    document.getElementById("download").href = dmg.browser_download_url;
    document.getElementById("dmg-link").href = dmg.browser_download_url;
    document.getElementById("download-label").textContent = `Download Maclean ${rel.tag_name.replace(/^v/, "")}`;
  }).catch(() => {});

  get("").then((info) => {
    if (!info.stargazers_count) return;   // "Star 0" isn't a good look
    document.querySelectorAll(".star-count").forEach((el) => {
      el.textContent = info.stargazers_count.toLocaleString();
      el.hidden = false;
    });
  }).catch(() => {});
})();
