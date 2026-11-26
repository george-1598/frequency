import { useState, type FormEvent } from 'react';
import { useRoom, savedName, saveName } from '../lib/room';
import { call } from '../lib/supabase';
import { goHome } from '../lib/route';
import Lobby from './Lobby';
import GameRound from './GameRound';
import Results from './Results';

/** A room: join prompt, lobby, the current round, or the results. */
export default function Room({ code, userId }: { code: string; userId: string | null }) {
  const { state, error, refresh, act } = useRoom(code, userId);

  if (!state) return <p className="loading">{error ?? 'Tuning in…'}</p>;
  if (state.missing)
    return (
      <section className="card center">
        <h2>That room doesn’t exist (anymore)</h2>
        <button className="btn btn-primary" onClick={goHome}>
          Back home
        </button>
      </section>
    );
  if (!state.joined) return <JoinPrompt code={code} onJoined={refresh} started={state.status !== 'lobby'} />;

  return (
    <>
      {error && <p className="error banner">{error}</p>}
      {state.status === 'lobby' && <Lobby state={state} act={act} />}
      {state.status === 'playing' && <GameRound state={state} act={act} />}
      {state.status === 'finished' && <Results state={state} act={act} />}
    </>
  );
}

function JoinPrompt({ code, onJoined, started }: { code: string; onJoined: () => void; started: boolean }) {
  const [name, setName] = useState(savedName);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const join = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    saveName(name);
    try {
      await call('ti_join_room', { p_code: code, p_name: name });
      onJoined();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not join');
    }
    setBusy(false);
  };
  return (
    <form className="card home-form" onSubmit={join}>
      <h2>Join room {code}</h2>
      {started && <p className="muted">A game is already going: you’ll join in from the next rounds.</p>}
      <label>
        <span>Your name</span>
        <input value={name} onChange={(e) => setName(e.target.value)} maxLength={24} placeholder="e.g. Ana" autoFocus />
      </label>
      <button className="btn btn-primary" disabled={busy || !name.trim()}>
        {busy ? 'Joining…' : 'Join'}
      </button>
      {error && <p className="error">{error}</p>}
      <button type="button" className="link" onClick={goHome}>
        Back home
      </button>
    </form>
  );
}
