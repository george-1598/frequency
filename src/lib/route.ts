import { useEffect, useState } from 'react';

/** #/ (home) or #/r/CODE (a room). */
export function useRoomCode(): string | null {
  const read = () => window.location.hash.match(/^#\/r\/([A-Za-z0-9]{4,8})$/)?.[1]?.toUpperCase() ?? null;
  const [code, setCode] = useState(read);
  useEffect(() => {
    const on = () => setCode(read());
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return code;
}

export const goToRoom = (code: string) => (window.location.hash = `#/r/${code}`);
export const goHome = () => (window.location.hash = '#/');
export const roomLink = (code: string) => `${window.location.origin}${import.meta.env.BASE_URL}#/r/${code}`;

export type AdminView = 'rooms' | 'stats' | 'scales';
export type AdminRoute = { view: AdminView } | { watch: string };

/** #/admin, #/admin/stats, #/admin/scales, #/admin/watch/CODE; null elsewhere. */
export function useAdminRoute(): AdminRoute | null {
  const read = (): AdminRoute | null => {
    const h = window.location.hash;
    const w = h.match(/^#\/admin\/watch\/([A-Za-z0-9]{4,8})$/);
    if (w) return { watch: w[1].toUpperCase() };
    const m = h.match(/^#\/admin(?:\/(stats|scales|rooms))?$/);
    return m ? { view: (m[1] as AdminView) ?? 'rooms' } : null;
  };
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const f = () => setRoute(read());
    window.addEventListener('hashchange', f);
    return () => window.removeEventListener('hashchange', f);
  }, []);
  return route;
}
export const openAdmin = (view: AdminView | { watch: string }) =>
  (window.location.hash = typeof view === 'string' ? (view === 'rooms' ? '#/admin' : `#/admin/${view}`) : `#/admin/watch/${view.watch}`);
