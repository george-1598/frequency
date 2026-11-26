import { useEffect, useState } from 'react';
import { call } from '../lib/supabase';
import { seatColor } from '../lib/room';
import Dial from './Dial';

interface RecapRound {
  n: number;
  psychic_name: string | null;
  left: string;
  right: string;
  clue: string | null;
  precision: number;
  target: number;
  guesses: { user_id: string; name: string; seat: number; value: number; points: number | null }[];
}

const BAND: Record<number, string> = { 4: 'Bullseye', 3: 'Close', 2: 'Near', 0: 'Missed' };

/** Every round of the finished game: scale, clue, target and everyone's guesses. */
export default function Recap({ code, game }: { code: string; game: number }) {
  const [rounds, setRounds] = useState<RecapRound[] | null>(null);
  useEffect(() => {
    call<RecapRound[]>('ti_room_recap', { p_code: code })
      .then((d) => setRounds(Array.isArray(d) ? d : []))
      .catch(() => setRounds([]));
  }, [code, game]);
  if (!rounds?.length) return null;

  // The single biggest miss of the game, for a laugh.
  const misses = rounds.flatMap((r) => r.guesses.map((g) => ({ n: r.n, name: g.name, off: Math.abs(Number(g.value) - Number(r.target)) })));
  const worst = misses.sort((a, b) => b.off - a.off)[0];

  return (
    <section className="recap">
      <h3 className="recap-title">Round by round</h3>
      {rounds.map((r) => (
        <article key={r.n} className="card recap-round">
          <header>
            <span>Round {r.n}</span>
            <span className="recap-creator">{r.psychic_name ?? 'Someone'}’s clue</span>
          </header>
          <p className="recap-clue">“{r.clue ?? '—'}”</p>
          <Dial
            value={Number(r.target)}
            showMain={false}
            target={{ center: Number(r.target), tol: r.precision }}
            needles={r.guesses.map((g) => ({ value: Number(g.value), color: seatColor(g.seat), label: g.name.slice(0, 1).toUpperCase() }))}
            left={r.left}
            right={r.right}
            label={`Round ${r.n}`}
          />
          {r.guesses.length > 0 ? (
            <ul className="recap-guesses">
              {r.guesses.map((g) => (
                <li key={g.user_id}>
                  <i style={{ background: seatColor(g.seat) }} />
                  {g.name}
                  <em>{BAND[Number(g.points ?? 0)] ?? ''}</em>
                  <strong>+{Number(g.points ?? 0)}</strong>
                  {worst && worst.n === r.n && worst.name === g.name && worst.off >= 20 && <span className="recap-worst">biggest miss</span>}
                </li>
              ))}
            </ul>
          ) : (
            <p className="muted center-text">Nobody guessed this one.</p>
          )}
        </article>
      ))}
    </section>
  );
}
