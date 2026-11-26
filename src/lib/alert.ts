import { useEffect, useRef, useState } from 'react';
import type { RoomState } from './room';

const SOUND_KEY = 'frequency-sound';
const readSound = () => {
  try {
    return localStorage.getItem(SOUND_KEY) !== 'off';
  } catch {
    return true;
  }
};

let ctx: AudioContext | null = null;
/** Phones only play sound after a tap, so open the audio on the first one. */
function unlockAudio() {
  try {
    const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return;
    ctx ??= new AC();
    if (ctx.state === 'suspended') void ctx.resume();
  } catch {
    // no audio
  }
}
if (typeof window !== 'undefined') {
  window.addEventListener('pointerdown', unlockAudio, { passive: true });
  window.addEventListener('keydown', unlockAudio);
}

/** A soft two-note chime. */
function chime() {
  if (!ctx || ctx.state !== 'running') return;
  const now = ctx.currentTime;
  [
    [880, 0],
    [1318.5, 0.14],
  ].forEach(([freq, at]) => {
    const osc = ctx!.createOscillator();
    const gain = ctx!.createGain();
    osc.type = 'sine';
    osc.frequency.value = freq;
    gain.gain.setValueAtTime(0, now + at);
    gain.gain.linearRampToValueAtTime(0.18, now + at + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.001, now + at + 0.5);
    osc.connect(gain).connect(ctx!.destination);
    osc.start(now + at);
    osc.stop(now + at + 0.55);
  });
}

/** What the game is waiting on *me* for right now, or null. */
function myTurn(state: RoomState | null): string | null {
  const r = state?.current;
  if (!state || state.status !== 'playing' || !r) return null;
  if (r.phase === 'clue' && r.psychic === state.me) return `create-${r.n}`;
  if (r.phase === 'guessing' && r.psychic !== state.me && !r.guesses.some((g) => g.user_id === state.me)) return `guess-${r.n}`;
  return null;
}

/**
 * A chime and a buzz when it becomes my turn (to set up a round, or to guess),
 * plus a marker in the tab title while the page is in the background.
 */
export function useTurnAlert(state: RoomState | null) {
  const [sound, setSoundState] = useState(readSound);
  const last = useRef<string | null | undefined>(undefined);
  const turn = myTurn(state);

  useEffect(() => {
    if (!state) return;
    const prev = last.current;
    last.current = turn;
    // Not on the first load (you just opened the page), only when it changes to a new turn.
    if (prev === undefined || !turn || turn === prev) return;
    if (sound) chime();
    try {
      navigator.vibrate?.([120, 80, 120]);
    } catch {
      // no vibration
    }
  }, [turn, state, sound]);

  useEffect(() => {
    const base = 'Frequency';
    const update = () => {
      document.title = turn && document.visibilityState === 'hidden' ? `● Your turn · ${base}` : base;
    };
    update();
    document.addEventListener('visibilitychange', update);
    return () => {
      document.removeEventListener('visibilitychange', update);
      document.title = base;
    };
  }, [turn]);

  const setSound = (on: boolean) => {
    setSoundState(on);
    try {
      localStorage.setItem(SOUND_KEY, on ? 'on' : 'off');
    } catch {
      // ignore
    }
    if (on) {
      unlockAudio();
      window.setTimeout(chime, 50);
    }
  };
  return { sound, setSound };
}
