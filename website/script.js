const year = document.querySelector('#year');
if (year) year.textContent = new Date().getFullYear();

const heritageRail = document.querySelector('.heritage-rail');
const railNumber = heritageRail?.querySelector('.rail-number');
const railZones = [...document.querySelectorAll('[data-rail-tone]')];
let railFrame;

function updateHeritageRail() {
  const focusLine = window.innerHeight * 0.48;
  const scrollableHeight = document.documentElement.scrollHeight - window.innerHeight;
  const scrollProgress = scrollableHeight > 0
    ? Math.min(1, Math.max(0, window.scrollY / scrollableHeight))
    : 0;
  const currentZone = railZones.reduce((closest, zone) => {
    const rect = zone.getBoundingClientRect();
    const distance = rect.top <= focusLine && rect.bottom >= focusLine
      ? 0
      : Math.min(Math.abs(rect.top - focusLine), Math.abs(rect.bottom - focusLine));
    return distance < closest.distance ? { zone, distance } : closest;
  }, { zone: railZones[0], distance: Infinity }).zone;

  heritageRail.dataset.tone = currentZone.dataset.railTone;
  railNumber.textContent = currentZone.dataset.railNumber;
  heritageRail.style.setProperty('--rail-progress', scrollProgress);

  railFrame = undefined;
}

function requestRailUpdate() {
  if (!railFrame) railFrame = requestAnimationFrame(updateHeritageRail);
}

if (heritageRail && railNumber && railZones.length) {
  window.addEventListener('scroll', requestRailUpdate, { passive: true });
  window.addEventListener('resize', requestRailUpdate);
  updateHeritageRail();
}

const tickerTrack = document.querySelector('.ticker-track');
const tickerTemplate = tickerTrack?.querySelector('.ticker-group');

function fillTicker() {
  const groupWidth = tickerTemplate.getBoundingClientRect().width;
  if (!groupWidth) return;

  tickerTrack.style.setProperty('--ticker-distance', `${groupWidth}px`);
  while (tickerTrack.scrollWidth < window.innerWidth + groupWidth * 2) {
    const clone = tickerTemplate.cloneNode(true);
    clone.setAttribute('aria-hidden', 'true');
    tickerTrack.appendChild(clone);
  }
}

function startTicker() {
  fillTicker();
  tickerTrack.getBoundingClientRect();
  tickerTrack.classList.add('is-ready');
}

if (tickerTrack && tickerTemplate) {
  fillTicker();
  window.addEventListener('resize', fillTicker);

  if (document.fonts?.ready) {
    document.fonts.ready.then(startTicker);
  } else {
    startTicker();
  }
}
