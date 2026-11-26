import { useState, type FormEvent } from 'react';
import { roomLink, goHome } from '../lib/route';
import { seatColor, type RoomState } from '../lib/room';

type Act = (fn: string, args?: Record<string, unknown>) => Promise<void>;
const PRECISION = [
  { v: 10, label: 'Easy' },
  { v: 7, label: 'Normal' },
  { v: 4, label: 'Hard' },
];

export function Avatar({ name, seat, size = 34 }: { name: string; seat: number; size?: number }) {
  return (
    <span className="avatar" style={{ background: seatColor(seat), width: size, height: size, fontSize: size * 0.45 }}>
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
}

/** Waiting room: share the code, see who's here, settings and custom scales. */
export default function Lobby({ state, act }: { state: RoomState; act: Act }) {
  const isHost = state.host === state.me;
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [left, setLeft] = useState('');
  const [right, setRight] = useState('');
  const run = async (fn: string, args?: Record<string, unknown>) => {
    setError(null);
    try {
      await act(fn, args);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    }
  };
  const share = async () => {
    const url = roomLink(state.code);
    try {
      if (navigator.share) return await navigator.share({ title: 'Tuned In', text: `Join my Tuned In room: ${state.code}`, url });
    } catch {
      return;
    }
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      setError('Couldn’t copy the link; share the code instead.');
    }
  };
  const addCard = async (e: FormEvent) => {
    e.preventDefault();
    await run('ti_add_card', { p_left: left, p_right: right });
    setLeft('');
    setRight('');
  };
  const rounds = state.players.length * state.rounds_per_player;

  return (
    <section className="stack">
      <div className="card room-code">
        <span className="kicker">Room code</span>
        <strong className="code">{state.code}</strong>
        <button className="btn" onClick={share}>
          {copied ? 'Link copied ✓' : '📤 Invite friends'}
        </button>
      </div>

      <div className="card">
        <h2>
          Players <small>{state.players.length} / 12</small>
        </h2>
        <ul className="players">
          {state.players.map((p) => (
            <li key={p.id}>
              <Avatar name={p.name} seat={p.seat} />
              <span className="player-name">
                {p.name}
                {p.id === state.me && <em> (you)</em>}
              </span>
              {p.id === state.host && <span title="Host">👑</span>}
              <span className={p.online ? 'dot is-on' : 'dot'} title={p.online ? 'Online' : 'Away'} />
            </li>
          ))}
        </ul>
        {state.players.length < 2 && <p className="muted">Waiting for at least one more player…</p>}
      </div>

      <div className="card">
        <h2>Settings</h2>
        <div className="setting">
          <span>Rounds as psychic, each</span>
          <div className="seg">
            {[1, 2, 3].map((n) => (
              <button key={n} aria-pressed={state.rounds_per_player === n} disabled={!isHost} onClick={() => run('ti_update_settings', { p_rounds_per_player: n, p_precision: state.precision })}>
                {n}
              </button>
            ))}
          </div>
        </div>
        <div className="setting">
          <span>Starting target size</span>
          <div className="seg">
            {PRECISION.map((p) => (
              <button key={p.v} aria-pressed={state.precision === p.v} disabled={!isHost} onClick={() => run('ti_update_settings', { p_rounds_per_player: state.rounds_per_player, p_precision: p.v })}>
                {p.label}
              </button>
            ))}
          </div>
        </div>
        <p className="muted">
          {rounds} rounds in total. Each psychic can still change the target size for their round.{!isHost && ' The host chooses the settings.'}
        </p>
      </div>

      <div className="card">
        <h2>
          Your own scales <small>optional</small>
        </h2>
        <p className="muted">Add scales only your group would get. They’re mixed into the deck of 100.</p>
        <form className="card-form" onSubmit={addCard}>
          <input value={left} onChange={(e) => setLeft(e.target.value)} maxLength={40} placeholder="Left, e.g. Never" aria-label="Left end" />
          <span>⟷</span>
          <input value={right} onChange={(e) => setRight(e.target.value)} maxLength={40} placeholder="Right, e.g. Always" aria-label="Right end" />
          <button className="btn" disabled={!left.trim() || !right.trim()}>
            Add
          </button>
        </form>
        {state.cards.length > 0 && (
          <ul className="custom-cards">
            {state.cards.map((c) => (
              <li key={c.id}>
                <span>
                  {c.left} ⟷ {c.right}
                </span>
                {(c.mine || isHost) && (
                  <button className="link" onClick={() => run('ti_remove_card', { p_id: c.id })} aria-label="Remove">
                    ✕
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      {error && <p className="error">{error}</p>}
      {isHost ? (
        <button className="btn btn-primary btn-big" onClick={() => run('ti_start_game')} disabled={state.players.length < 2}>
          Start the game
        </button>
      ) : (
        <p className="waiting">Waiting for the host to start…</p>
      )}
      <button className="link" onClick={() => run('ti_leave_room').then(goHome)}>
        Leave the room
      </button>
    </section>
  );
}
