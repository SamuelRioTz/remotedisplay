(function () {
  const SUPPORTED = ['en', 'es', 'de'];
  const STORAGE_KEY = 'remotedisplay-lang';
  let translations = {};
  let currentLang = 'en';

  function detectLanguage() {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved && SUPPORTED.includes(saved)) return saved;
    } catch (e) { /* storage unavailable */ }
    const browser = (navigator.language || '').split('-')[0];
    return SUPPORTED.includes(browser) ? browser : 'en';
  }

  function applyTranslations() {
    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      const key = el.getAttribute('data-i18n');
      if (translations[key] !== undefined) {
        el.textContent = translations[key];
      }
    });
    document.querySelectorAll('[data-i18n-html]').forEach(function (el) {
      const key = el.getAttribute('data-i18n-html');
      if (translations[key] !== undefined) {
        el.innerHTML = translations[key];
      }
    });
    document.querySelectorAll('.lang-btn').forEach(function (btn) {
      btn.classList.toggle('active', btn.getAttribute('data-lang') === currentLang);
    });
    document.documentElement.lang = currentLang;
  }

  async function loadLanguage(lang) {
    try {
      const res = await fetch('l10n/' + lang + '.json');
      translations = await res.json();
      currentLang = lang;
      try { localStorage.setItem(STORAGE_KEY, lang); } catch (e) { /* ignore */ }
      applyTranslations();
    } catch (e) {
      if (lang !== 'en') loadLanguage('en');
    }
  }

  window.switchLanguage = function (lang) {
    if (SUPPORTED.includes(lang)) loadLanguage(lang);
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      loadLanguage(detectLanguage());
    });
  } else {
    loadLanguage(detectLanguage());
  }
})();
