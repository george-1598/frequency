import { useState } from 'react';
import ShareButton from './ShareButton';
import { seatColor, type RoomState } from '../lib/room';

type Act = (fn: string, args?: Record<string, unknown>) => Promise<void>;

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
  const [error, setError] = useState<string | null>(null);
  const run = async (fn: string, args?: Record<string, unknown>) => {
    setError(null);
    try {
      await act(fn, args);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    }
  };
  const rounds = state.players.length * state.rounds_per_player;

  return (
    <section className="stack">
      <div className="card room-code">
        <span className="kicker">Room code</span>
        <strong className="code">{state.code}</strong>
        <ShareButton code={state.code} />
        <span className="muted">Friends can join any time, even mid-game.</span>
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
          <span>Rounds as creator, each</span>
          <div className="seg">
            {[1, 2, 3].map((n) => (
              <button key={n} aria-pressed={state.rounds_per_player === n} disabled={!isHost} onClick={() => run('ti_update_settings', { p_rounds_per_player: n, p_precision: state.precision })}>
                {n}
              </button>
            ))}
          </div>
        </div>
        <p className="muted">
          {rounds} rounds in total.{!isHost && ' The host chooses the settings.'}
        </p>
      </div>

      {error && <p className="error">{error}</p>}
      {isHost ? (
        <button className="btn btn-primary btn-big" onClick={() => run('ti_start_game')} disabled={state.players.length < 2}>
          Start the game
        </button>
      ) : (
        <p className="waiting">Waiting for the host to start…</p>
      )}
    </section>
  );
}
