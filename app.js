(() => {
  const repo = "smalhasib/maclean";

  // Tab lists (the tools showcase and the install methods). Without JS every panel simply shows.
  const lists = [...document.querySelectorAll('[role="tablist"]')];
  const show = (list, tab) => {
    [...list.querySelectorAll('[role="tab"]')].forEach((t) => {
      const on = t === tab;
      t.setAttribute("aria-selected", on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
  };
  lists.forEach((list) => {
    const tabs = [...list.querySelectorAll('[role="tab"]')];
    show(list, tabs.find((t) => t.getAttribute("aria-selected") === "true") || tabs[0]);
    tabs.forEach((t, i) => {
      t.addEventListener("click", () => show(list, t));
      t.addEventListener("keydown", (e) => {
        const next = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
        if (!next) return;
        const to = tabs[(i + next + tabs.length) % tabs.length];
        show(list, to);
        to.focus();
      });
    });
  });

  // Links that point at a tab open it first (the Homebrew button in the hero).
  document.querySelectorAll("[data-tab]").forEach((link) => {
    link.addEventListener("click", () => {
      const tab = document.getElementById(link.dataset.tab);
      show(tab.parentElement, tab);
    });
  });

  // Copy buttons
  document.addEventListener("click", async (e) => {
    const el = e.target.closest("[data-copy]");
    if (!el) return;
    const before = el.textContent;
    try {
      await navigator.clipboard.writeText(el.dataset.copy);
      el.textContent = "Copied";
    } catch {
      el.textContent = "Press ⌘C";
    }
    setTimeout(() => { el.textContent = before; }, 1400);
  });

  // The latest release's name and disk image. The static links still work if this fails.
  fetch(`https://api.github.com/repos/${repo}/releases/latest`).then((r) => (r.ok ? r.json() : Promise.reject())).then((rel) => {
    const dmg = rel.assets.find((a) => a.name.endsWith(".dmg"));
    if (!dmg) return;
    ["download", "dmg-link", "nav-download"].forEach((id) => { const a = document.getElementById(id); if (a) a.href = dmg.browser_download_url; });
    document.getElementById("download-label").textContent = `Download Maclean ${rel.tag_name.replace(/^v/, "")}`;
  }).catch(() => {});
})();
