import { useEffect, useState } from 'react';
import { call } from '../lib/supabase';
import { openAdmin } from '../lib/route';
import { seatColor } from '../lib/room';
import Dial from './Dial';
import { Avatar } from './Lobby';

interface WatchState {
  missing?: boolean;
  code: string;
  host: string;
  status: 'lobby' | 'playing' | 'finished';
  round: number;
  rounds_total: number;
  players: { id: string; name: string; seat: number; score: number; online: boolean }[];
  current: {
    n: number;
    psychic: string;
    left: string;
    right: string;
    clue: string | null;
    phase: 'clue' | 'guessing' | 'reveal';
    precision: number;
    target: number | null;
    guesses: { user_id: string; value: number; points: number | null }[];
  } | null;
}

/** A silent, live view of any room. Players don't see the admin. */
export default function AdminWatch({ code }: { code: string }) {
  const [s, setS] = useState<WatchState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [peek, setPeek] = useState(false);
  useEffect(() => {
    let alive = true;
    const load = () =>
      call<WatchState>('ti_admin_room_state', { p_code: code }).then(
        (d) => alive && (setS(d), setError(null)),
        (e) => alive && setError(e instanceof Error ? e.message : 'Connection problem'),
      );
    void load();
    const t = window.setInterval(load, 2000);
    return () => {
      alive = false;
      window.clearInterval(t);
    };
  }, [code]);

  const back = (
    <button className="link link-left" onClick={() => openAdmin('rooms')}>
      ← Back to rooms
    </button>
  );
  if (!s) return <p className="loading">{error ?? 'Tuning in…'}</p>;
  if (s.missing)
    return (
      <section className="stack">
        {back}
        <p className="card center-text">Room {code} doesn’t exist anymore.</p>
      </section>
    );

  const r = s.current;
  const byId = new Map(s.players.map((p) => [p.id, p]));
  const creator = r ? byId.get(r.psychic) : undefined;
  const locked = new Set(r?.guesses.map((g) => g.user_id));
  const waiting = r?.phase === 'guessing' ? s.players.filter((p) => p.id !== r.psychic && !locked.has(p.id)) : [];
  const revealed = r?.phase === 'reveal';
  const showSecrets = revealed || peek;
  const sorted = s.players.slice().sort((a, b) => b.score - a.score);

  return (
    <section className="stack">
      {back}
      <div className="room-bar watch-bar">
        <span>
          Watching <strong>{s.code}</strong>
        </span>
        <span className="watch-live">
          <i /> live · players can’t see you
        </span>
      </div>

      {s.status === 'finished' ? (
        <p className="card center-text">This game has finished.</p>
      ) : s.status === 'lobby' || !r ? (
        <p className="card center-text">Waiting in the lobby.</p>
      ) : (
        <>
          <div className="round-head">
            <span>
              Round {r.n} / {s.rounds_total}
            </span>
            <span className="round-psychic">{creator?.name ?? 'Someone'} is the creator</span>
          </div>
          {r.phase === 'clue' ? (
            <div className="card">
              <p className="waiting">
                {creator?.name ?? 'The creator'} is preparing the round<span className="dots" />
              </p>
              <Dial value={50} showMain={false} left="?" right="?" label="Waiting for the round" />
            </div>
          ) : (
            <>
              <p className="clue-big">“{r.clue}”</p>
              {waiting.length > 0 && (
                <div className="still-guessing">
                  <span className="still-label">
                    Still guessing<span className="dots" />
                  </span>
                  <ul>
                    {waiting.map((p) => (
                      <li key={p.id} className={p.online ? undefined : 'is-away'}>
                        <Avatar name={p.name} seat={p.seat} size={22} />
                        {p.name}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              <div className="card">
                <Dial
                  value={r.target ?? 50}
                  showMain={false}
                  target={showSecrets && r.target != null ? { center: r.target, tol: r.precision } : null}
                  needles={
                    showSecrets
                      ? r.guesses.map((g) => {
                          const p = byId.get(g.user_id);
                          return { value: Number(g.value), color: p ? seatColor(p.seat) : '#999', label: p?.name.slice(0, 1).toUpperCase() };
                        })
                      : []
                  }
                  left={r.left}
                  right={r.right}
                  label="The dial"
                />
                {!revealed && (
                  <label className="watch-peek">
                    <input type="checkbox" checked={peek} onChange={(e) => setPeek(e.target.checked)} />
                    Peek at the secret spot and locked guesses
                  </label>
                )}
                {revealed && (
                  <ul className="recap-guesses">
                    {r.guesses
                      .slice()
                      .sort((a, b) => (b.points ?? 0) - (a.points ?? 0))
                      .map((g) => (
                        <li key={g.user_id}>
                          <i style={{ background: seatColor(byId.get(g.user_id)?.seat ?? 0) }} />
                          {byId.get(g.user_id)?.name ?? 'Someone'}
                          <em />
                          <strong>+{Number(g.points ?? 0)}</strong>
                        </li>
                      ))}
                  </ul>
                )}
              </div>
            </>
          )}
        </>
      )}

      <div className="card scores">
        <h3>Scores</h3>
        <ol>
          {sorted.map((p) => (
            <li key={p.id}>
              <Avatar name={p.name} seat={p.seat} size={24} />
              <span>
                {p.name}
                {p.id === s.host && <em> (host)</em>}
              </span>
              {!p.online && <span className="away">away</span>}
              <strong>{Number(p.score)}</strong>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
