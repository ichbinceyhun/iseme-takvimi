// Vercel her yayında bu dosyayı çalıştırır:
// - siteyi dist/ klasörüne kopyalar,
// - Supabase bilgilerini ortam değişkenlerinden config.js'e yazar (bilgiler depoda tutulmaz),
// - sayfadaki satır içi kodun özetini hesaplayıp sıkı bir güvenlik politikası (CSP) ekler.
import fs from 'node:fs';
import crypto from 'node:crypto';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL ve SUPABASE_ANON_KEY ortam değişkenleri tanımlı değil.');
  process.exit(1);
}
if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)) {
  console.error('SUPABASE_URL beklenen biçimde değil: https://<proje>.supabase.co');
  process.exit(1);
}

let html = fs.readFileSync('index.html', 'utf8');
const hashes = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .map((m) => `'sha256-${crypto.createHash('sha256').update(m[1], 'utf8').digest('base64')}'`);

const csp = [
  "default-src 'self'",
  `script-src 'self' ${hashes.join(' ')}`,
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  'font-src https://fonts.gstatic.com',
  "img-src 'self' data:",
  `connect-src ${url}`,
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join('; ');

if (!html.includes('<meta charset="utf-8">')) { console.error('index.html içinde charset meta etiketi yok.'); process.exit(1); }
html = html.replace('<meta charset="utf-8">', `<meta charset="utf-8">\n<meta http-equiv="Content-Security-Policy" content="${csp}">`);

fs.rmSync('dist', { recursive: true, force: true });
fs.mkdirSync('dist/vendor', { recursive: true });
fs.writeFileSync('dist/index.html', html);
for (const f of fs.readdirSync('vendor')) fs.copyFileSync(`vendor/${f}`, `dist/vendor/${f}`);
fs.writeFileSync('dist/config.js', `window.ISEME_CONFIG = ${JSON.stringify({ url, key })};\n`);
console.log('Site dist/ klasörüne hazırlandı. Satır içi kod özetleri:', hashes.length);
