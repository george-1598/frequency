import { useSession } from './lib/session';
import { goHome, useRoomCode } from './lib/route';
import Home from './components/Home';
import Room from './components/Room';
import { SUPABASE_URL } from './config';

export default function App() {
  const { userId, error } = useSession();
  const code = useRoomCode();
  const notConfigured = SUPABASE_URL.includes('REPLACE_WITH');
  return (
    <div className="app">
      {code && (
        <header className="topbar">
          <button className="topbar-brand" onClick={goHome}>
            📻 Tuned In
          </button>
        </header>
      )}
      <main>
        {notConfigured && <p className="error banner">The game isn’t connected to its database yet.</p>}
        {error && <p className="error banner">Couldn’t connect: {error}</p>}
        {code ? <Room code={code} userId={userId} /> : <Home ready={Boolean(userId)} />}
      </main>
    </div>
  );
}
