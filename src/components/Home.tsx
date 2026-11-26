import { useState, type FormEvent } from 'react';
import { call } from '../lib/supabase';
import { goToRoom } from '../lib/route';
import { saveName, savedName } from '../lib/room';
import Dial from './Dial';

/** Enter your name, then create a room or join one with its code. */
export default function Home({ ready }: { ready: boolean }) {
  const [name, setName] = useState(savedName);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState<'create' | 'join' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [demo, setDemo] = useState(68);

  const run = async (kind: 'create' | 'join', e?: FormEvent) => {
    e?.preventDefault();
    if (!name.trim()) return setError('Enter your name first');
    setBusy(kind);
    setError(null);
    saveName(name);
    try {
      const room = kind === 'create' ? await call<string>('ti_create_room', { p_name: name }) : await call<string>('ti_join_room', { p_code: code, p_name: name });
      goToRoom(room);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong');
    }
    setBusy(null);
  };

  return (
    <section className="home">
      <header className="brand">
        <span className="brand-mark">📻</span>
        <h1>Tuned In</h1>
        <p>One player knows the secret spot. Everyone else tunes in.</p>
      </header>
      <div className="card home-demo" aria-hidden>
        <p className="clue-big">“A cup of hot chocolate”</p>
        <Dial value={demo} onChange={setDemo} left="Cold" right="Hot" label="Try the dial" />
      </div>
      <div className="card home-form">
        <label>
          <span>Your name</span>
          <input value={name} onChange={(e) => setName(e.target.value)} maxLength={24} placeholder="e.g. Ana" autoComplete="nickname" />
        </label>
        <button className="btn btn-primary" onClick={() => run('create')} disabled={!ready || busy !== null}>
          {busy === 'create' ? 'Creating…' : 'Create a room'}
        </button>
        <div className="or">or join one</div>
        <form className="join-row" onSubmit={(e) => run('join', e)}>
          <input value={code} onChange={(e) => setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ''))} maxLength={5} placeholder="CODE" aria-label="Room code" className="code-input" />
          <button className="btn" disabled={!ready || busy !== null || code.length < 5}>
            {busy === 'join' ? 'Joining…' : 'Join'}
          </button>
        </form>
        {error && <p className="error">{error}</p>}
      </div>
      <details className="card howto">
        <summary>How to play</summary>
        <ol>
          <li>Each round, one player is the <strong>psychic</strong>. Only they see where the secret spot is on a scale, like <em>Cold ⟷ Hot</em>.</li>
          <li>The psychic gives a clue, like <em>“A cup of hot chocolate”</em>.</li>
          <li>Everyone else moves their needle to where they think the clue sits, and locks it in.</li>
          <li>Reveal! The middle band is worth 4 points, then 3, then 2. The psychic scores the average of everyone’s points.</li>
          <li>The psychic changes every round. Most points at the end wins.</li>
        </ol>
      </details>
    </section>
  );
}
