/* One-tap install.
 *
 * The APK is named by version (herdr-mobile-0.1.67.apk), so there is no fixed
 * download link. On load this reads the latest release from GitHub -- the same
 * way the app's own update sheet finds its file (release_info.dart) -- and
 * points every <a data-hm-apk> button at the APK's real address, so a tap
 * starts the download straight away with no stop at the releases page. Where a
 * button carries a <span data-hm-apk-label>, the label gains the version and
 * size, so the person knows what they are getting and how big it is. One
 * request per page load, no timer, no retry. If the call fails, or JS is off,
 * the buttons keep the releases-page link they were written with.
 */
(function () {
  'use strict';
  var btns = document.querySelectorAll('a[data-hm-apk]');
  if (!btns.length) return;
  fetch('https://api.github.com/repos/tuan3w/herdr-mobile/releases/latest', { cache: 'no-store' })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (rel) {
      var tag = String(rel.tag_name || '').replace(/^v/, '');
      if (!/^\d+\.\d+\.\d+$/.test(tag)) return;
      var apk = (rel.assets || []).filter(function (a) { return a.name === 'herdr-mobile-' + tag + '.apk'; })[0];
      if (!apk || !apk.browser_download_url) return;
      var mb = Math.max(1, Math.round(apk.size / 1048576));
      btns.forEach(function (b) {
        b.href = apk.browser_download_url;
        var label = b.querySelector('[data-hm-apk-label]');
        if (label) label.textContent = 'Download ' + tag + ' \u00b7 ' + mb + ' MB';
      });
    })
    .catch(function () {});
})();
