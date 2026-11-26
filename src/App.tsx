import { useSession } from './lib/session';
import { goHome, useIsAdminRoute, useRoomCode } from './lib/route';
import Admin from './components/Admin';
import Home from './components/Home';
import Room from './components/Room';
import { SUPABASE_URL } from './config';
import Logo from './components/Logo';

export default function App() {
  const { userId, error } = useSession();
  const code = useRoomCode();
  const adminRoute = useIsAdminRoute();
  const notConfigured = SUPABASE_URL.includes('REPLACE_WITH');
  return (
    <div className="app">
      {(code || adminRoute) && (
        <header className="topbar">
          <button className="topbar-brand" onClick={goHome}>
            <Logo />
          </button>
        </header>
      )}
      <main>
        {notConfigured && <p className="error banner">The game isn’t connected to its database yet.</p>}
        {error && <p className="error banner">Couldn’t connect: {error}</p>}
        {adminRoute ? <Admin userId={userId} /> : code ? <Room code={code} userId={userId} /> : <Home ready={Boolean(userId)} />}
      </main>
    </div>
  );
}
