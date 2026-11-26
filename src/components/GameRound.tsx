import { useEffect, useState, type FormEvent } from 'react';
import { seatColor, type RoomState } from '../lib/room';
import Dial from './Dial';
import { Avatar } from './Lobby';
import { randomSuggestion } from '../lib/suggestions';
import ShareButton from './ShareButton';

type Act = (fn: string, args?: Record<string, unknown>) => Promise<void>;

const BAND_NAME: Record<number, string> = { 4: 'Bullseye!', 3: 'Close', 2: 'Near', 0: 'Missed' };

/** One round: the creator's clue, everyone's guesses, and the reveal. */
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
  const tol = r.precision ?? state.precision;

  return (
    <section className="stack">
      <div className="round-head">
        <span>
          Round {r.n} / {state.rounds_total}
        </span>
        <span className="round-psychic">
          {isPsychic ? 'You’re the creator' : `${psychic?.name ?? 'Someone'} is the creator`}
        </span>
      </div>

      {state.players.length > 1 && state.round > state.rounds_total - state.players.length && (
        <div className="more-rounds">
          <span>{state.round >= state.rounds_total ? 'This is the last round.' : 'Last round for some players.'}</span>
          <button className="btn btn-small" onClick={() => run('ti_add_round')}>
            ➕ One more round for everyone
          </button>
        </div>
      )}

      {r.phase === 'clue' &&
        (isPsychic ? (
          <PsychicClue state={state} run={run} />
        ) : (
          <div className="card">
            <p className="waiting">
              {psychic?.name ?? 'The creator'} is preparing the round<span className="dots" />
            </p>
            <Dial value={50} showMain={false} left="?" right="?" label="Waiting for the round" />
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
          {waitingFor.length > 0 && <StillGuessing players={waitingFor} me={state.me} />}
          {isPsychic ? (
            <div className="card">
              <Dial value={r.target ?? 50} showMain={false} target={r.target != null ? { center: r.target, tol } : null} left={r.left} right={r.right} label="The secret spot" />
              {guessers.length === 0 ? (
                <div className="alone">
                  <p>Nobody else is here yet. Invite friends: they can guess this round as soon as they join.</p>
                  <ShareButton code={state.code} />
                </div>
              ) : (
                <p className="muted center-text">Only you can see the target.</p>
              )}
              {guessers.length > 0 && <RevealNow waiting={waitingFor} run={run} />}
            </div>
          ) : lockedIds.has(state.me) ? (
            <div className="card">
              <Dial value={r.guesses.find((g) => g.user_id === state.me)?.value ?? 50} left={r.left} right={r.right} label="Your locked guess" />
              <p className="locked">🔒 Locked in.</p>
              {isHost && waitingFor.length > 0 && <RevealNow waiting={waitingFor} run={run} />}
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

const PRECISION = [
  { tol: 7, label: 'Generous' },
  { tol: 4, label: 'Balanced' },
  { tol: 3, label: 'Precise' },
];

/** The round's creator sets it up, like the advent calendar's editor. */
function PsychicClue({ state, run }: { state: RoomState; run: (fn: string, args?: Record<string, unknown>) => Promise<void> }) {
  const r = state.current!;
  // A fresh random scale and clue every time the editor opens (refreshing gives a new one); all editable.
  const [start] = useState(() => randomSuggestion());
  const [left, setLeft] = useState(start.left);
  const [right, setRight] = useState(start.right);
  const [clue, setClue] = useState(start.clue);
  const [spot, setSpot] = useState(r.target ?? 50);
  const [tol, setTol] = useState(4); // Balanced
  const [busy, setBusy] = useState(false);
  const suggest = () => {
    const e = randomSuggestion(clue);
    setLeft(e.left);
    setRight(e.right);
    setClue(e.clue);
  };
  const send = async (ev: FormEvent) => {
    ev.preventDefault();
    setBusy(true);
    await run('ti_set_round', { p_left: left, p_right: right, p_clue: clue, p_target: spot, p_precision: tol });
    setBusy(false);
  };
  return (
    <form className="card editor" onSubmit={send}>
      <p className="psychic-tip">Only you can see this. Set up the round, then send it to everyone.</p>
      <div className="editor-row">
        <label>
          <span>Left end</span>
          <input value={left} onChange={(e) => setLeft(e.target.value)} maxLength={40} placeholder="e.g. Quiet place" />
        </label>
        <label>
          <span>Right end</span>
          <input value={right} onChange={(e) => setRight(e.target.value)} maxLength={40} placeholder="e.g. Loud place" />
        </label>
      </div>
      <label>
        <span>The clue</span>
        <input value={clue} onChange={(e) => setClue(e.target.value)} maxLength={80} placeholder="e.g. A library on a Sunday morning" />
      </label>
      <button type="button" className="link link-left" onClick={suggest}>
        🎲 Suggest another example
      </button>
      <span className="editor-label">Drag the needle to the secret spot</span>
      <Dial value={spot} onChange={setSpot} target={{ center: spot, tol }} left={left} right={right} label="Secret spot" />
      <label>
        <span>Precision</span>
        <select value={tol} onChange={(e) => setTol(Number(e.target.value))}>
          {PRECISION.map((p) => (
            <option key={p.tol} value={p.tol}>
              {p.label}
            </option>
          ))}
        </select>
      </label>
      <small className="editor-help">The blue middle band is worth 4 points, orange 3, yellow 2. Nobody sees where it is until the reveal.</small>
      <button className="btn btn-primary btn-big" disabled={busy || !left.trim() || !right.trim() || !clue.trim()}>
        {busy ? 'Sending…' : 'Send to everyone'}
      </button>
    </form>
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

const nameList = (names: string[]) => (names.length < 2 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`);

/** End the guessing early; asks first, naming who'll miss out. */
function RevealNow({ waiting, run }: { waiting: RoomState['players']; run: (fn: string, args?: Record<string, unknown>) => Promise<void> }) {
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const reveal = async () => {
    setBusy(true);
    await run('ti_force_reveal');
    setBusy(false);
    setConfirm(false);
  };
  if (!confirm)
    return (
      <button className="btn btn-reveal-now" onClick={() => (waiting.length ? setConfirm(true) : void reveal())}>
        Reveal now
      </button>
    );
  const names = nameList(waiting.map((p) => p.name));
  return (
    <div className="reveal-confirm">
      <span>
        {names} {waiting.length === 1 ? 'hasn’t' : 'haven’t'} guessed yet. Reveal anyway?
        <small>{waiting.length === 1 ? 'They’ll' : 'They’ll each'} get 0 points this round.</small>
      </span>
      <div>
        <button className="btn btn-small" onClick={() => setConfirm(false)} disabled={busy}>
          Wait
        </button>
        <button className="btn btn-small btn-primary" onClick={reveal} disabled={busy}>
          {busy ? 'Revealing…' : 'Reveal'}
        </button>
      </div>
    </div>
  );
}

/** Who still hasn't locked in a guess, shown to everyone. */
function StillGuessing({ players, me }: { players: RoomState['players']; me: string }) {
  return (
    <div className="still-guessing" aria-live="polite">
      <span className="still-label">
        Still guessing<span className="dots" />
      </span>
      <ul>
        {players.map((p) => (
          <li key={p.id} className={p.online ? undefined : 'is-away'}>
            <Avatar name={p.name} seat={p.seat} size={22} />
            {p.id === me ? 'You' : p.name}
            {!p.online && <em>away</em>}
          </li>
        ))}
      </ul>
    </div>
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
  const guessed = new Set(r.guesses.map((g) => g.user_id));
  const missed = state.players.filter((p) => p.id !== r.psychic && !guessed.has(p.id));
  return (
    <>
      <p className="clue-big">“{r.clue ?? '—'}”</p>
      <div className="card">
        <Dial
          value={r.target ?? 50}
          showMain={false}
          target={show && r.target != null ? { center: r.target, tol: r.precision ?? state.precision } : null}
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
          {missed.map((p) => (
            <li key={p.id} className="is-missed">
              <Avatar name={p.name} seat={p.seat} size={26} />
              <span>{p.name}</span>
              <em>Didn’t guess</em>
              <strong>+0</strong>
            </li>
          ))}
          {byId.get(r.psychic) && (
            <li className="is-psychic">
              <Avatar name={byId.get(r.psychic)!.name} seat={byId.get(r.psychic)!.seat} size={26} />
              <span>{byId.get(r.psychic)!.name}</span>
              <em className="creator-tag">Creator</em>
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
