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

/** True on #/admin. */
export function useIsAdminRoute(): boolean {
  const [on, setOn] = useState(() => window.location.hash === '#/admin');
  useEffect(() => {
    const f = () => setOn(window.location.hash === '#/admin');
    window.addEventListener('hashchange', f);
    return () => window.removeEventListener('hashchange', f);
  }, []);
  return on;
}
