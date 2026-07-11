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

const screenshotLinks = [...document.querySelectorAll('.screenshot-card > a')];
const screenshotLightbox = document.querySelector('#screenshot-lightbox');
const lightboxImage = screenshotLightbox?.querySelector('.lightbox-image');
const lightboxCaption = screenshotLightbox?.querySelector('.lightbox-caption');
const lightboxCount = screenshotLightbox?.querySelector('.lightbox-count');
const lightboxClose = screenshotLightbox?.querySelector('.lightbox-close');
const lightboxPrevious = screenshotLightbox?.querySelector('.lightbox-prev');
const lightboxNext = screenshotLightbox?.querySelector('.lightbox-next');
let lightboxIndex = 0;
let lightboxReturnFocus;

function showScreenshot(index) {
  lightboxIndex = (index + screenshotLinks.length) % screenshotLinks.length;
  const link = screenshotLinks[lightboxIndex];
  const thumbnail = link.querySelector('img');
  const caption = link.closest('.screenshot-card')?.querySelector('figcaption');

  lightboxImage.src = link.href;
  lightboxImage.alt = thumbnail?.alt || '';
  lightboxCaption.textContent = caption?.textContent.trim().replace(/\s+/g, ' ') || '';
  lightboxCount.textContent = `${lightboxIndex + 1} / ${screenshotLinks.length}`;

  const nextIndex = (lightboxIndex + 1) % screenshotLinks.length;
  const previousIndex = (lightboxIndex - 1 + screenshotLinks.length) % screenshotLinks.length;
  [nextIndex, previousIndex].forEach((adjacentIndex) => {
    const preload = new Image();
    preload.src = screenshotLinks[adjacentIndex].href;
  });
}

function openScreenshotGallery(index, trigger) {
  lightboxReturnFocus = trigger;
  showScreenshot(index);
  screenshotLightbox.hidden = false;
  document.body.classList.add('lightbox-open');
  lightboxClose.focus();
}

function closeScreenshotGallery() {
  screenshotLightbox.hidden = true;
  lightboxImage.src = '';
  document.body.classList.remove('lightbox-open');
  lightboxReturnFocus?.focus();
}

if (screenshotLinks.length && screenshotLightbox && lightboxImage && lightboxCaption && lightboxCount) {
  screenshotLinks.forEach((link, index) => {
    link.addEventListener('click', (event) => {
      event.preventDefault();
      openScreenshotGallery(index, link);
    });
  });

  lightboxPrevious.addEventListener('click', () => showScreenshot(lightboxIndex - 1));
  lightboxNext.addEventListener('click', () => showScreenshot(lightboxIndex + 1));
  lightboxClose.addEventListener('click', closeScreenshotGallery);
  lightboxImage.addEventListener('click', closeScreenshotGallery);

  screenshotLightbox.addEventListener('click', (event) => {
    if (event.target === screenshotLightbox) closeScreenshotGallery();
  });

  document.addEventListener('keydown', (event) => {
    if (screenshotLightbox.hidden) return;
    if (event.key === 'Escape') closeScreenshotGallery();
    if (event.key === 'ArrowLeft') showScreenshot(lightboxIndex - 1);
    if (event.key === 'ArrowRight') showScreenshot(lightboxIndex + 1);
  });
}
