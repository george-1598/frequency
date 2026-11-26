import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Served from https://george-1598.github.io/tuned-in/
export default defineConfig({
  base: '/tuned-in/',
  plugins: [react()],
});
