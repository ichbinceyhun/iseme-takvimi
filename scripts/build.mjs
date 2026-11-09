// Vercel her yayında bu dosyayı çalıştırır: siteyi dist/ klasörüne kopyalar ve
// Supabase bilgilerini ortam değişkenlerinden config.js'e yazar. Bilgiler depoda tutulmaz.
import fs from 'node:fs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL ve SUPABASE_ANON_KEY ortam değişkenleri tanımlı değil.');
  process.exit(1);
}

fs.rmSync('dist', { recursive: true, force: true });
fs.mkdirSync('dist');
fs.copyFileSync('index.html', 'dist/index.html');
fs.writeFileSync('dist/config.js', `window.ISEME_CONFIG = ${JSON.stringify({ url, key })};\n`);
console.log('Site dist/ klasörüne hazırlandı.');
