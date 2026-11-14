import { build } from 'vite';
import { mkdir, copyFile } from 'node:fs/promises';

await build();
await mkdir('www', { recursive: true });

for (const file of [
  'manifest.webmanifest',
  'sw.js',
  'icon.svg',
  'icon-192.png',
  'icon-512.png'
]) {
  await copyFile(file, `www/${file}`);
}

console.log('IQ Challenge web bundle created in ./www');
