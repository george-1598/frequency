import type { RoomState } from '../lib/room';
import { goHome } from '../lib/route';
import { Avatar } from './Lobby';

type Act = (fn: string, args?: Record<string, unknown>) => Promise<void>;

/** Final scores with a podium, then play again (host) or leave. */
export default function Results({ state, act }: { state: RoomState; act: Act }) {
  const sorted = state.players.slice().sort((a, b) => b.score - a.score);
  const top = Number(sorted[0]?.score ?? 0);
  const winners = sorted.filter((p) => Number(p.score) === top);
  const podium = [sorted[1], sorted[0], sorted[2]];
  const isHost = state.host === state.me;
  return (
    <section className="stack results">
      <Confetti />
      <h2 className="results-title">{winners.length > 1 ? 'It’s a tie! 🎉' : `${winners[0]?.name ?? 'Someone'} wins! 🏆`}</h2>
      <div className="podium">
        {podium.map((p, i) =>
          p ? (
            <div key={p.id} className={`podium-step step-${i}`}>
              <Avatar name={p.name} seat={p.seat} size={i === 1 ? 56 : 44} />
              <span className="podium-name">{p.name}</span>
              <strong>{Number(p.score)}</strong>
              <div className="podium-block">{i === 1 ? 1 : i === 0 ? 2 : 3}</div>
            </div>
          ) : (
            <div key={i} className={`podium-step step-${i} is-empty`} />
          ),
        )}
      </div>
      <div className="card scores">
        <ol>
          {sorted.map((p) => (
            <li key={p.id}>
              <Avatar name={p.name} seat={p.seat} size={24} />
              <span>
                {p.name}
                {p.id === state.me && <em> (you)</em>}
              </span>
              <strong>{Number(p.score)}</strong>
            </li>
          ))}
        </ol>
      </div>
      {isHost ? (
        <button className="btn btn-primary btn-big" onClick={() => act('ti_play_again')}>
          Play again
        </button>
      ) : (
        <p className="waiting">The host can start another game.</p>
      )}
      <button className="link" onClick={() => act('ti_leave_room').then(goHome)}>
        Leave the room
      </button>
    </section>
  );
}

const COLORS = ['#FFC857', '#FF7A93', '#7B61FF', '#4ECDC4', '#ffffff'];
function Confetti() {
  return (
    <div className="confetti" aria-hidden>
      {Array.from({ length: 60 }, (_, i) => (
        <span
          key={i}
          style={{
            left: `${(i * 37) % 100}%`,
            background: COLORS[i % COLORS.length],
            animationDelay: `${(i % 12) * 0.15}s`,
            animationDuration: `${2.6 + (i % 5) * 0.4}s`,
          }}
        />
      ))}
    </div>
  );
}
