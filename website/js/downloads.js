// Fills the Download section with the assets of the latest GitHub release.
// Without JS (or if the API is unavailable) every button already points to the
// releases page, so this only upgrades the links to direct downloads.
(function () {
  const REPO = 'SamuelRioTz/remotedisplay';
  const API = 'https://api.github.com/repos/' + REPO + '/releases/latest';
  const ASSETS = {
    'mac-server':    /^RemoteDisplay-Server-.*-macos\.dmg$/i,
    'mac-client':    /^RemoteDisplay-.*-macos-client\.dmg$/i,
    'win-installer': /^RemoteDisplay-Setup-.*\.exe$/i,
    'win-portable':  /^RemoteDisplay-.*-windows-x64-portable\.zip$/i,
    'android':       /^RemoteDisplay-.*-android-arm64\.apk$/i,
    'ios':           /^RemoteDisplay-.*-ios\.ipa$/i
  };

  function fmtSize(bytes) {
    if (bytes >= 1024 * 1024) return Math.round(bytes / (1024 * 1024)) + ' MB';
    return Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }

  fetch(API, { headers: { Accept: 'application/vnd.github+json' } })
    .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
    .then(function (rel) {
      if (rel.tag_name) {
        document.querySelectorAll('[data-release-tag]').forEach(function (el) { el.textContent = rel.tag_name; });
        document.querySelectorAll('[data-release-wrap]').forEach(function (el) { el.hidden = false; });
      }
      Object.keys(ASSETS).forEach(function (key) {
        const asset = (rel.assets || []).find(function (a) { return ASSETS[key].test(a.name); });
        if (!asset) return;
        document.querySelectorAll('[data-asset="' + key + '"]').forEach(function (link) {
          link.href = asset.browser_download_url;
          const size = link.querySelector('[data-asset-size]');
          if (size) { size.textContent = '· ' + fmtSize(asset.size); size.hidden = false; }
        });
      });
    })
    .catch(function () { /* keep the releases-page links */ });
})();
