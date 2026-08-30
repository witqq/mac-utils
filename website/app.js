(() => {
  const languageButtons = [...document.querySelectorAll("[data-language]")];
  const localizedNodes = [...document.querySelectorAll("[data-en][data-ru]")];
  const localizedImages = [...document.querySelectorAll("[data-localized-image]")];

  function chooseInitialLanguage() {
    const requested = new URLSearchParams(window.location.search).get("lang");
    if (requested === "en" || requested === "ru") return requested;
    const stored = localStorage.getItem("mac-utils-language");
    if (stored === "en" || stored === "ru") return stored;
    return navigator.language.toLowerCase().startsWith("ru") ? "ru" : "en";
  }

  function applyLanguage(language) {
    document.documentElement.lang = language;
    localizedNodes.forEach((node) => { node.textContent = node.dataset[language]; });
    localizedImages.forEach((image) => {
      image.src = image.dataset[`${language}Src`];
      image.alt = image.dataset[`${language}Alt`] || "";
    });
    languageButtons.forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.language === language));
    });
    document.title = language === "ru"
      ? "Mac Utils — Сценарии для дисплеев. Одна клавиша."
      : "Mac Utils — Display workflows. One shortcut.";
    localStorage.setItem("mac-utils-language", language);
  }

  languageButtons.forEach((button) => {
    button.addEventListener("click", () => applyLanguage(button.dataset.language));
  });

  applyLanguage(chooseInitialLanguage());
})();
