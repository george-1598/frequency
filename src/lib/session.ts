import { useEffect, useState } from 'react';
import { supabase } from './supabase';

/** Players don't need an account: each phone signs in anonymously once and keeps that identity. */
export function useSession(): { userId: string | null; error: string | null } {
  const [userId, setUserId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (data.session) return !cancelled && setUserId(data.session.user.id);
      const { data: signed, error: err } = await supabase.auth.signInAnonymously();
      if (cancelled) return;
      if (err || !signed.user) setError(err?.message ?? 'Could not connect');
      else setUserId(signed.user.id);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return { userId, error };
}
