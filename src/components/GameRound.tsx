import { useEffect, useState, type FormEvent } from 'react';
import { seatColor, type RoomState } from '../lib/room';
import Dial from './Dial';
import { Avatar } from './Lobby';

type Act = (fn: string, args?: Record<string, unknown>) => Promise<void>;

const BAND_NAME: Record<number, string> = { 4: 'Bullseye!', 3: 'Close', 2: 'Near', 0: 'Missed' };

/** One round: the psychic's clue, everyone's guesses, and the reveal. */
export default function GameRound({ state, act }: { state: RoomState; act: Act }) {
  const r = state.current;
  const [error, setError] = useState<string | null>(null);
  const run = async (fn: string, args?: Record<string, unknown>) => {
    setError(null);
    try {
      await act(fn, args);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    }
  };
  if (!r) return <p className="loading">Dealing the next card…</p>;

  const isHost = state.host === state.me;
  const isPsychic = r.psychic === state.me;
  const psychic = state.players.find((p) => p.id === r.psychic);
  const guessers = state.players.filter((p) => p.id !== r.psychic);
  const lockedIds = new Set(r.guesses.map((g) => g.user_id));
  const waitingFor = guessers.filter((p) => !lockedIds.has(p.id));
  const tol = state.precision;

  return (
    <section className="stack">
      <div className="round-head">
        <span>
          Round {r.n} / {state.rounds_total}
        </span>
        <span className="round-psychic">
          🔮 {isPsychic ? 'You’re the psychic' : `${psychic?.name ?? 'Someone'} is the psychic`}
        </span>
      </div>

      {r.phase === 'clue' &&
        (isPsychic ? (
          <PsychicClue state={state} run={run} />
        ) : (
          <div className="card">
            <p className="waiting">
              {psychic?.name ?? 'The psychic'} is thinking of a clue<span className="dots" />
            </p>
            <Dial value={50} showMain={false} left={r.left} right={r.right} label="The scale for this round" />
            {isHost && psychic && !psychic.online && (
              <button className="link" onClick={() => run('ti_skip_round')}>
                {psychic.name} seems to be away: skip this round
              </button>
            )}
          </div>
        ))}

      {r.phase === 'guessing' && (
        <>
          <p className="clue-big">“{r.clue}”</p>
          {isPsychic ? (
            <div className="card">
              <Dial value={r.target ?? 50} showMain={false} target={r.target != null ? { center: r.target, tol } : null} left={r.left} right={r.right} label="The secret spot" />
              <p className="muted center-text">Only you can see the target. Waiting for {waitingFor.map((p) => p.name).join(', ') || 'everyone'}…</p>
              <LockedList guessers={guessers} locked={lockedIds} />
              <button className="link" onClick={() => run('ti_force_reveal')}>
                Reveal now
              </button>
            </div>
          ) : lockedIds.has(state.me) ? (
            <div className="card">
              <Dial value={r.guesses.find((g) => g.user_id === state.me)?.value ?? 50} left={r.left} right={r.right} label="Your locked guess" />
              <p className="locked">🔒 Locked in. Waiting for {waitingFor.map((p) => p.name).join(', ') || 'the reveal'}…</p>
              <LockedList guessers={guessers} locked={lockedIds} />
              {isHost && waitingFor.length > 0 && (
                <button className="link" onClick={() => run('ti_force_reveal')}>
                  Reveal now
                </button>
              )}
            </div>
          ) : (
            <GuessPanel key={r.n} left={r.left} right={r.right} run={run} />
          )}
        </>
      )}

      {r.phase === 'reveal' && <Reveal state={state} run={run} />}

      {error && <p className="error">{error}</p>}
      <Scores state={state} />
    </section>
  );
}

function PsychicClue({ state, run }: { state: RoomState; run: (fn: string, args?: Record<string, unknown>) => Promise<void> }) {
  const r = state.current!;
  const [clue, setClue] = useState('');
  const [busy, setBusy] = useState(false);
  const send = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    await run('ti_give_clue', { p_clue: clue });
    setBusy(false);
  };
  return (
    <div className="card psychic">
      <p className="psychic-tip">Only you see the target. Give a clue that points the others to it.</p>
      <Dial value={r.target ?? 50} showMain={false} target={r.target != null ? { center: r.target, tol: state.precision } : null} left={r.left} right={r.right} label="The secret spot" />
      <form className="clue-form" onSubmit={send}>
        <input value={clue} onChange={(e) => setClue(e.target.value)} maxLength={80} placeholder="Your clue, e.g. A cup of hot chocolate" aria-label="Your clue" autoFocus />
        <button className="btn btn-primary" disabled={busy || !clue.trim()}>
          {busy ? 'Sending…' : 'Send clue'}
        </button>
      </form>
      <button className="link" onClick={() => run('ti_skip_card')} disabled={r.skips >= 3}>
        {r.skips >= 3 ? 'No more redraws this round' : `🔄 Draw another card (${3 - r.skips} left)`}
      </button>
    </div>
  );
}

function GuessPanel({ left, right, run }: { left: string; right: string; run: (fn: string, args?: Record<string, unknown>) => Promise<void> }) {
  const [value, setValue] = useState(50);
  const [busy, setBusy] = useState(false);
  const lock = async () => {
    setBusy(true);
    await run('ti_lock_guess', { p_value: value });
    setBusy(false);
  };
  return (
    <div className="card">
      <Dial value={value} onChange={setValue} left={left} right={right} label="Your guess" />
      <div className="nudge">
        <button className="btn btn-small" onClick={() => setValue((v) => Math.max(0, v - 1))} aria-label="Move left">
          ◀
        </button>
        <span className="muted">Drag the needle</span>
        <button className="btn btn-small" onClick={() => setValue((v) => Math.min(100, v + 1))} aria-label="Move right">
          ▶
        </button>
      </div>
      <button className="btn btn-primary btn-big" onClick={lock} disabled={busy}>
        {busy ? 'Locking…' : 'Lock it in'}
      </button>
    </div>
  );
}

function LockedList({ guessers, locked }: { guessers: RoomState['players']; locked: Set<string> }) {
  return (
    <ul className="locked-list">
      {guessers.map((p) => (
        <li key={p.id} className={locked.has(p.id) ? 'is-locked' : undefined}>
          <Avatar name={p.name} seat={p.seat} size={26} />
          {p.name}
          <span>{locked.has(p.id) ? '🔒' : '…'}</span>
        </li>
      ))}
    </ul>
  );
}

function Reveal({ state, run }: { state: RoomState; run: (fn: string, args?: Record<string, unknown>) => Promise<void> }) {
  const r = state.current!;
  const [show, setShow] = useState(false);
  // A little drumroll before the bands appear.
  useEffect(() => {
    const t = window.setTimeout(() => setShow(true), 700);
    return () => window.clearTimeout(t);
  }, [r.n]);
  const byId = new Map(state.players.map((p) => [p.id, p]));
  const scored = r.guesses.filter((g) => g.points != null);
  const psychicPts = scored.length ? Math.round((scored.reduce((s, g) => s + (g.points ?? 0), 0) / scored.length) * 2) / 2 : 0;
  const last = r.n >= state.rounds_total;
  return (
    <>
      <p className="clue-big">“{r.clue ?? '—'}”</p>
      <div className="card">
        <Dial
          value={r.target ?? 50}
          showMain={false}
          target={show && r.target != null ? { center: r.target, tol: state.precision } : null}
          needles={r.guesses.map((g) => {
            const p = byId.get(g.user_id);
            return { value: g.value ?? 50, color: p ? seatColor(p.seat) : '#999', label: p?.name.slice(0, 1).toUpperCase() };
          })}
          left={r.left}
          right={r.right}
          label="The reveal"
        />
        <ul className="round-points">
          {r.guesses
            .slice()
            .sort((a, b) => (b.points ?? 0) - (a.points ?? 0))
            .map((g) => {
              const p = byId.get(g.user_id);
              return (
                <li key={g.user_id}>
                  {p && <Avatar name={p.name} seat={p.seat} size={26} />}
                  <span>{p?.name ?? 'Someone'}</span>
                  <em>{BAND_NAME[g.points ?? 0] ?? ''}</em>
                  <strong>+{g.points ?? 0}</strong>
                </li>
              );
            })}
          {byId.get(r.psychic) && (
            <li className="is-psychic">
              <Avatar name={byId.get(r.psychic)!.name} seat={byId.get(r.psychic)!.seat} size={26} />
              <span>{byId.get(r.psychic)!.name}</span>
              <em>🔮 psychic</em>
              <strong>+{psychicPts}</strong>
            </li>
          )}
        </ul>
      </div>
      <button className="btn btn-primary btn-big" onClick={() => run('ti_next_round')}>
        {last ? 'See the final scores 🏆' : 'Next round →'}
      </button>
    </>
  );
}

function Scores({ state }: { state: RoomState }) {
  const sorted = state.players.slice().sort((a, b) => b.score - a.score);
  return (
    <div className="card scores">
      <h3>Scores</h3>
      <ol>
        {sorted.map((p) => (
          <li key={p.id}>
            <Avatar name={p.name} seat={p.seat} size={24} />
            <span>
              {p.name}
              {p.id === state.me && <em> (you)</em>}
            </span>
            {!p.online && <span className="away">away</span>}
            <strong>{Number(p.score)}</strong>
          </li>
        ))}
      </ol>
    </div>
  );
}
