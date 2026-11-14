import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  publicDir: false,
  build: {
    outDir: 'www',
    emptyOutDir: true,
    target: 'es2022',
    rollupOptions: {
      input: {
        game: 'index.html',
        admin: 'admin.html'
      }
    }
  }
});
