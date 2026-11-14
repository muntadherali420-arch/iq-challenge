import { build } from 'vite';
import { mkdir, copyFile } from 'node:fs/promises';

await build();
await mkdir('www', { recursive: true });
await mkdir('assets', { recursive: true });
await copyFile('icon.svg', 'assets/icon.svg');

for (const file of [
  'manifest.webmanifest',
  'sw.js',
  'icon.svg',
  'icon-192.png',
  'icon-512.png',
  'privacy.html',
  'delete-account.html'
]) {
  await copyFile(file, `www/${file}`);
}

console.log('IQ Challenge web bundle created in ./www');
