(() => {
  "use strict";

  const root = document.documentElement;
  root.classList.add("js");

  const themeButton = document.querySelector(".theme-toggle");
  const themeColor = document.querySelector('meta[name="theme-color"]');
  const themeKey = "kanai-theme";
  const systemTheme = window.matchMedia?.("(prefers-color-scheme: dark)");

  const readSavedTheme = () => {
    try {
      return window.localStorage.getItem(themeKey);
    } catch {
      return null;
    }
  };

  const saveTheme = (theme) => {
    try {
      window.localStorage.setItem(themeKey, theme);
    } catch {
      // A blocked storage API should not prevent the page from working.
    }
  };

  const preferredTheme = readSavedTheme() || (systemTheme?.matches ? "dark" : "light");
  let activeTheme = preferredTheme === "dark" ? "dark" : "light";

  const renderTheme = () => {
    root.dataset.theme = activeTheme;
    if (themeColor) themeColor.setAttribute("content", activeTheme === "dark" ? "#0b1215" : "#f4f1e9");
    if (themeButton) {
      const isDark = activeTheme === "dark";
      themeButton.setAttribute("aria-pressed", String(isDark));
      themeButton.setAttribute("aria-label", isDark ? "ライトテーマに切り替える" : "ダークテーマに切り替える");
    }
  };

  renderTheme();

  themeButton?.addEventListener("click", () => {
    activeTheme = activeTheme === "dark" ? "light" : "dark";
    saveTheme(activeTheme);
    renderTheme();
  });

  systemTheme?.addEventListener?.("change", (event) => {
    if (readSavedTheme()) return;
    activeTheme = event.matches ? "dark" : "light";
    renderTheme();
  });

  const menuButton = document.querySelector(".menu-toggle");
  const navigation = document.querySelector(".site-nav");

  const setMenuState = (open) => {
    if (!menuButton || !navigation) return;
    menuButton.setAttribute("aria-expanded", String(open));
    navigation.classList.toggle("is-open", open);
    const label = menuButton.querySelector(".sr-only");
    if (label) label.textContent = open ? "メニューを閉じる" : "メニューを開く";
  };

  menuButton?.addEventListener("click", () => {
    setMenuState(menuButton.getAttribute("aria-expanded") !== "true");
  });

  navigation?.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => setMenuState(false));
  });

  document.addEventListener("click", (event) => {
    if (!navigation?.classList.contains("is-open")) return;
    if (navigation.contains(event.target) || menuButton?.contains(event.target)) return;
    setMenuState(false);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    const wasOpen = navigation?.classList.contains("is-open");
    setMenuState(false);
    if (wasOpen) menuButton?.focus();
  });

  const revealItems = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const revealObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      { threshold: 0.08, rootMargin: "0px 0px -32px" },
    );
    revealItems.forEach((item) => revealObserver.observe(item));
  } else {
    revealItems.forEach((item) => item.classList.add("is-visible"));
  }

  const tierData = {
    mozc: {
      badge: "NO MODEL",
      ram: "model file 0",
      name: "MozcOnly",
      description: "変換、composition、local learning。モデルなしでも成立する基準のtierです。",
      uses: ["base conversion", "offline profile", "zero model memory"],
    },
    tiny: {
      badge: "OPTIONAL TIER",
      ram: "model file ~500 MiB",
      name: "Tiny",
      description: "短いambiguity解決やrepair。0.6B前後・Q4を例に、メモリが少ない環境向けの入口に置きます。",
      uses: ["short ambiguity", "local repair", "~4 GiB RAM guidance"],
    },
    compact: {
      badge: "OPTIONAL TIER",
      ram: "model file ~1.2 GiB",
      name: "Compact",
      description: "semantic rerankとexplicit repairを担う、実用的な中間tier。model sizeは目安で、backendのoverheadに依存します。",
      uses: ["semantic rerank", "explicit repair", "~6 GiB RAM guidance"],
    },
    balanced: {
      badge: "OPTIONAL TIER",
      ram: "model file ~2.7 GiB",
      name: "Balanced",
      description: "long-formの明示的なwriting assistを想定したtier。キー入力の標準pathには置きません。",
      uses: ["explicit writing assist", "longer context", "~12 GiB RAM guidance"],
    },
  };

  const tierButtons = document.querySelectorAll(".tier-button");
  const tierBadge = document.getElementById("tier-badge");
  const tierRam = document.getElementById("tier-ram");
  const tierName = document.getElementById("tier-name");
  const tierDescription = document.getElementById("tier-description");
  const tierUseList = document.getElementById("tier-use-list");

  const renderTier = (tierKey) => {
    const tier = tierData[tierKey];
    if (!tier || !tierBadge || !tierRam || !tierName || !tierDescription || !tierUseList) return;

    tierBadge.textContent = tier.badge;
    tierRam.textContent = tier.ram;
    tierName.textContent = tier.name;
    tierDescription.textContent = tier.description;
    tierUseList.replaceChildren(
      ...tier.uses.map((use) => {
        const item = document.createElement("span");
        item.textContent = use;
        return item;
      }),
    );

    tierButtons.forEach((button) => {
      const active = button.dataset.tier === tierKey;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
  };

  tierButtons.forEach((button, index) => {
    button.addEventListener("click", () => renderTier(button.dataset.tier));
    button.addEventListener("keydown", (event) => {
      if (!["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"].includes(event.key)) return;
      event.preventDefault();
      const offset = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : -1;
      const nextIndex = (index + offset + tierButtons.length) % tierButtons.length;
      tierButtons[nextIndex].focus();
      renderTier(tierButtons[nextIndex].dataset.tier);
    });
  });

  const copyText = async (text) => {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }

    const helper = document.createElement("textarea");
    helper.value = text;
    helper.setAttribute("readonly", "");
    helper.style.position = "fixed";
    helper.style.opacity = "0";
    document.body.appendChild(helper);
    helper.select();
    const copied = document.execCommand("copy");
    helper.remove();
    return copied;
  };

  document.querySelectorAll("[data-copy]").forEach((button) => {
    const status = button.closest(".command-copy")?.querySelector(".copy-status");
    button.addEventListener("click", async () => {
      const text = button.dataset.copy || "";
      try {
        const copied = await copyText(text);
        if (status) status.textContent = copied ? "コピーしました。" : "コピーできませんでした。手動で選択してください。";
      } catch {
        if (status) status.textContent = "コピーできませんでした。手動で選択してください。";
      }
      window.setTimeout(() => {
        if (status) status.textContent = "";
      }, 2600);
    });
  });

  const year = document.getElementById("current-year");
  if (year) year.textContent = String(new Date().getFullYear());
})();
