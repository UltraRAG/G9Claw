// Regenerate 9GClaw favicon, in-app logo, and PWA icons from the source logo
// in `ui/src/assets/9gclaw-logo-source.png`. Run from the project root:
//
//   node ui/public/generate-icons.js
//
// or from ui/:
//
//   node public/generate-icons.js

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const PUBLIC = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(PUBLIC, '..', '..');
const SOURCE_LOGO = path.join(REPO_ROOT, 'ui', 'src', 'assets', '9gclaw-logo-source.png');

function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

async function sourceIconBuffer(size) {
  const meta = await sharp(SOURCE_LOGO).metadata();
  const square = Math.min(meta.width, meta.height);
  const left = Math.floor(((meta.width || square) - square) / 2);
  const top = Math.floor(((meta.height || square) - square) / 2);
  return sharp(SOURCE_LOGO)
    .extract({ left, top, width: square, height: square })
    .resize(size, size, { fit: 'cover' })
    .png()
    .toBuffer();
}

function embeddedSvg(pngBase64, size) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" width="${size}" height="${size}"><image href="data:image/png;base64,${pngBase64}" width="${size}" height="${size}" preserveAspectRatio="xMidYMid slice"/></svg>`;
}

async function writePng(rel, size) {
  const out = path.join(PUBLIC, rel);
  ensureParent(out);
  fs.writeFileSync(out, await sourceIconBuffer(size));
}

(async () => {
  if (!fs.existsSync(SOURCE_LOGO)) {
    throw new Error(`Missing source logo: ${SOURCE_LOGO}`);
  }

  const logoSizes = [32, 64, 128, 256, 512];
  const pwaSizes = [72, 96, 128, 144, 152, 192, 384, 512];

  await writePng('favicon.png', 64);
  for (const size of logoSizes) {
    await writePng(`logo-${size}.png`, size);
  }
  for (const size of pwaSizes) {
    const png = await sourceIconBuffer(size);
    const pngPath = path.join(PUBLIC, 'icons', `icon-${size}x${size}.png`);
    const svgPath = path.join(PUBLIC, 'icons', `icon-${size}x${size}.svg`);
    ensureParent(pngPath);
    fs.writeFileSync(pngPath, png);
    fs.writeFileSync(svgPath, embeddedSvg(png.toString('base64'), size), 'utf8');
  }

  const logo512 = await sourceIconBuffer(512);
  fs.writeFileSync(path.join(PUBLIC, 'logo.svg'), embeddedSvg(logo512.toString('base64'), 512), 'utf8');
  const favicon64 = await sourceIconBuffer(64);
  fs.writeFileSync(path.join(PUBLIC, 'favicon.svg'), embeddedSvg(favicon64.toString('base64'), 64), 'utf8');

  console.log('Done - 9GClaw icon assets regenerated.');
})();
