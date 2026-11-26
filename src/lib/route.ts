import { useEffect, useState } from 'react';

/** #/ (home) or #/r/CODE (a room). */
export function useRoomCode(): string | null {
  const read = () => window.location.hash.match(/^#\/r\/([A-Za-z0-9]{4,6})$/)?.[1]?.toUpperCase() ?? null;
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
