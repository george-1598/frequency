import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Served from https://george-1598.github.io/frequency/
export default defineConfig({
  base: '/frequency/',
  plugins: [react()],
});
