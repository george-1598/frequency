import { useCallback, useEffect, useRef, useState } from 'react';
import { call, supabase } from './supabase';

export interface Player {
  id: string;
  name: string;
  seat: number;
  score: number;
  online: boolean;
}
export interface Guess {
  user_id: string;
  value: number | null;
  points: number | null;
}
export interface Round {
  n: number;
  psychic: string;
  left: string;
  right: string;
  clue: string | null;
  phase: 'clue' | 'guessing' | 'reveal';
  skips: number;
  target: number | null;
  guesses: Guess[];
}
export interface RoomState {
  missing?: boolean;
  code: string;
  joined: boolean;
  me: string;
  host: string;
  status: 'lobby' | 'playing' | 'finished';
  round: number;
  rounds_total: number;
  rounds_per_player: number;
  precision: number;
  players: Player[];
  cards: { id: number; left: string; right: string; mine: boolean }[];
  current: Round | null;
}

/** Live room state: refetched whenever the room's tick changes (Realtime), plus a slow poll as a fallback. */
export function useRoom(code: string, userId: string | null) {
  const [state, setState] = useState<RoomState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inflight = useRef(false);
  const again = useRef(false);

  const refresh = useCallback(async () => {
    if (!userId) return;
    if (inflight.current) {
      again.current = true;
      return;
    }
    inflight.current = true;
    try {
      setState(await call<RoomState>('get_room_state', { p_code: code }));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Connection problem');
    } finally {
      inflight.current = false;
      if (again.current) {
        again.current = false;
        void refresh();
      }
    }
  }, [code, userId]);

  useEffect(() => {
    if (!userId) return;
    void refresh();
    const channel = supabase
      .channel(`room-${code}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'room_ticks', filter: `room=eq.${code}` }, () => void refresh())
      .subscribe();
    const poll = window.setInterval(() => void refresh(), 5000);
    const beat = window.setInterval(() => void call('heartbeat', { p_code: code }).catch(() => undefined), 20000);
    void call('heartbeat', { p_code: code }).catch(() => undefined);
    const onVisible = () => document.visibilityState === 'visible' && void refresh();
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      void supabase.removeChannel(channel);
      window.clearInterval(poll);
      window.clearInterval(beat);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [code, userId, refresh]);

  /** Run a room action, then refresh right away (Realtime will follow for everyone else). */
  const act = useCallback(
    async (fn: string, args: Record<string, unknown> = {}) => {
      await call(fn, { p_code: code, ...args });
      await refresh();
    },
    [code, refresh],
  );

  return { state, error, refresh, act };
}

const NAME_KEY = 'tuned-in-name';
export const savedName = () => {
  try {
    return localStorage.getItem(NAME_KEY) ?? '';
  } catch {
    return '';
  }
};
export const saveName = (n: string) => {
  try {
    localStorage.setItem(NAME_KEY, n.trim());
  } catch {
    // ignore
  }
};

/** A colour per seat, for needles and avatars. */
export const SEAT_COLORS = ['#FF6B8B', '#4ECDC4', '#FFC857', '#9B8CFF', '#5DD39E', '#FF9F43', '#54A0FF', '#F78FB3', '#26DE81', '#FD9644', '#A29BFE', '#FDCB6E'];
export const seatColor = (seat: number) => SEAT_COLORS[seat % SEAT_COLORS.length];
