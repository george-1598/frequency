import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { call } from '../lib/supabase';
import { goHome } from '../lib/route';
import { Avatar } from './Lobby';

interface AdminPlayer {
  id: string;
  name: string;
  seat: number;
  score: number;
  online: boolean;
  left: boolean;
  last_seen: string;
}
interface AdminRoom {
  code: string;
  status: 'lobby' | 'playing' | 'finished';
  round: number;
  rounds_total: number;
  created_at: string;
  last_active: string;
  phase: 'clue' | 'guessing' | 'reveal' | null;
  clue: string | null;
  creator: string | null;
  host: string;
  players: AdminPlayer[];
}
interface Overview {
  rooms: AdminRoom[];
  online: number;
  active_rooms: number;
  rooms_today: number;
}

const ACTIVE_MS = 10 * 60 * 1000;
const ago = (iso: string) => {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
};
const PHASE: Record<string, string> = { clue: 'creator is setting up', guessing: 'guessing', reveal: 'reveal' };

/** #/admin: every room, who's in it, and tools to tidy up. Password-protected. */
export default function Admin({ userId }: { userId: string | null }) {
  const [admin, setAdmin] = useState<boolean | null>(null);
  useEffect(() => {
    if (!userId) return;
    call<boolean>('ti_is_admin').then(setAdmin, () => setAdmin(false));
  }, [userId]);
  if (admin === null) return <p className="loading">Checking…</p>;
  return admin ? <Dashboard onLock={() => setAdmin(false)} /> : <Unlock onUnlocked={() => setAdmin(true)} />;
}

function Unlock({ onUnlocked }: { onUnlocked: () => void }) {
  const [pw, setPw] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      if (await call<boolean>('ti_admin_unlock', { p_password: pw })) onUnlocked();
      else setError('Wrong password');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong');
    }
    setBusy(false);
  };
  return (
    <form className="card home-form" onSubmit={submit}>
      <h2>Admin</h2>
      <label>
        <span>Password</span>
        <input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="current-password" autoFocus />
      </label>
      <button className="btn btn-primary" disabled={busy || !pw}>
        {busy ? 'Checking…' : 'Unlock'}
      </button>
      {error && <p className="error">{error}</p>}
      <button type="button" className="link" onClick={goHome}>
        Back home
      </button>
    </form>
  );
}

type Filter = 'all' | 'active' | 'idle' | 'finished';

function Dashboard({ onLock }: { onLock: () => void }) {
  const [data, setData] = useState<Overview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [hours, setHours] = useState(6);
  const [confirmClean, setConfirmClean] = useState(false);

  const load = useCallback(async () => {
    try {
      setData(await call<Overview>('ti_admin_overview'));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load');
    }
  }, []);
  useEffect(() => {
    void load();
    const t = window.setInterval(() => void load(), 10000);
    return () => window.clearInterval(t);
  }, [load]);

  const run = async (fn: string, args: Record<string, unknown>, done?: string) => {
    setError(null);
    try {
      const n = await call<unknown>(fn, args);
      if (done) setNotice(done.replace('{n}', String(n)));
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    }
  };

  if (!data) return <p className="loading">{error ?? 'Loading rooms…'}</p>;
  const isActive = (r: AdminRoom) => Date.now() - new Date(r.last_active).getTime() < ACTIVE_MS;
  const shown = data.rooms.filter((r) =>
    filter === 'all' ? true : filter === 'finished' ? r.status === 'finished' : filter === 'active' ? isActive(r) : !isActive(r),
  );
  const idleCount = data.rooms.filter((r) => Date.now() - new Date(r.last_active).getTime() > hours * 3600 * 1000).length;

  return (
    <section className="stack admin">
      <div className="admin-head">
        <h2>Admin</h2>
        <button
          className="btn btn-small"
          onClick={async () => {
            await call('ti_admin_lock').catch(() => undefined);
            onLock();
          }}
        >
          Lock
        </button>
      </div>

      <div className="admin-stats">
        <Stat n={data.online} label="online now" />
        <Stat n={data.active_rooms} label="active rooms" />
        <Stat n={data.rooms.length} label="rooms in total" />
        <Stat n={data.rooms_today} label="new today" />
      </div>

      <div className="card admin-clean">
        <span>Remove rooms nobody has used for more than</span>
        <div className="admin-clean-row">
          <div className="seg">
            {[1, 6, 24].map((h) => (
              <button key={h} aria-pressed={hours === h} onClick={() => (setHours(h), setConfirmClean(false))}>
                {h} h
              </button>
            ))}
          </div>
          {confirmClean ? (
            <span className="admin-confirm">
              <button className="btn btn-small" onClick={() => setConfirmClean(false)}>
                Cancel
              </button>
              <button
                className="btn btn-small btn-danger"
                onClick={() => {
                  setConfirmClean(false);
                  void run('ti_admin_cleanup', { p_hours: hours }, 'Removed {n} idle room(s).');
                }}
              >
                Remove {idleCount}
              </button>
            </span>
          ) : (
            <button className="btn btn-small" disabled={idleCount === 0} onClick={() => setConfirmClean(true)}>
              Clean up ({idleCount})
            </button>
          )}
        </div>
        <small className="muted">Rooms are also removed automatically after 2 days without activity.</small>
      </div>

      {notice && (
        <p className="admin-notice" onClick={() => setNotice(null)}>
          {notice}
        </p>
      )}
      {error && <p className="error">{error}</p>}

      <div className="seg admin-filter">
        {(['all', 'active', 'idle', 'finished'] as Filter[]).map((f) => (
          <button key={f} aria-pressed={filter === f} onClick={() => setFilter(f)}>
            {f[0].toUpperCase() + f.slice(1)}
          </button>
        ))}
      </div>

      {shown.length === 0 && <p className="muted center-text">No rooms here.</p>}
      {shown.map((r) => (
        <RoomCard key={r.code} room={r} active={isActive(r)} run={run} />
      ))}

      <PasswordChange run={run} />
    </section>
  );
}

function Stat({ n, label }: { n: number; label: string }) {
  return (
    <div className="admin-stat">
      <strong>{n}</strong>
      <span>{label}</span>
    </div>
  );
}

type Run = (fn: string, args: Record<string, unknown>, done?: string) => Promise<void>;

function RoomCard({ room: r, active, run }: { room: AdminRoom; active: boolean; run: Run }) {
  const [confirm, setConfirm] = useState<null | 'delete' | 'end' | { kick: AdminPlayer }>(null);
  const present = r.players.filter((p) => !p.left);
  const left = r.players.filter((p) => p.left);
  const status =
    r.status === 'finished'
      ? 'Finished'
      : r.status === 'lobby'
        ? 'Lobby'
        : `Round ${r.round} / ${r.rounds_total}${r.phase ? ` · ${PHASE[r.phase]}` : ''}`;
  return (
    <article className={`card admin-room${active ? ' is-active' : ''}`}>
      <header>
        <strong className="admin-code">{r.code}</strong>
        <span className={`admin-pill admin-pill--${r.status}`}>{status}</span>
      </header>
      <p className="admin-meta">
        <span className={`admin-dot${active ? ' is-on' : ''}`} />
        Last activity {ago(r.last_active)} · created {ago(r.created_at)}
      </p>
      {r.clue && r.status === 'playing' && <p className="admin-clue">“{r.clue}”</p>}

      <ul className="admin-players">
        {present.map((p) => (
          <li key={p.id}>
            <Avatar name={p.name} seat={p.seat} size={26} />
            <span className="admin-pname">
              {p.name}
              {p.id === r.host && <em>host</em>}
              {p.id === r.creator && r.status === 'playing' && <em>creator</em>}
            </span>
            <span className={p.online ? 'admin-online' : 'admin-away'}>{p.online ? 'online' : ago(p.last_seen)}</span>
            <b>{Number(p.score)}</b>
            <button className="admin-x" aria-label={`Remove ${p.name}`} onClick={() => setConfirm({ kick: p })}>
              ×
            </button>
          </li>
        ))}
        {present.length === 0 && <li className="muted">Nobody left in this room</li>}
      </ul>
      {left.length > 0 && <p className="admin-left">Left: {left.map((p) => p.name).join(', ')}</p>}

      {confirm ? (
        <div className="admin-confirm-box">
          <span>
            {confirm === 'delete'
              ? `Delete room ${r.code}? Everyone in it is sent back to the start.`
              : confirm === 'end'
                ? 'End this game and show the final scores?'
                : `Remove ${confirm.kick.name} from the room?`}
          </span>
          <div>
            <button className="btn btn-small" onClick={() => setConfirm(null)}>
              Cancel
            </button>
            <button
              className="btn btn-small btn-danger"
              onClick={() => {
                const c = confirm;
                setConfirm(null);
                if (c === 'delete') void run('ti_admin_delete_room', { p_code: r.code }, `Room ${r.code} deleted.`);
                else if (c === 'end') void run('ti_admin_end_game', { p_code: r.code }, `Game in ${r.code} ended.`);
                else void run('ti_admin_kick', { p_code: r.code, p_user: c.kick.id }, `${c.kick.name} removed from ${r.code}.`);
              }}
            >
              {confirm === 'delete' ? 'Delete' : confirm === 'end' ? 'End game' : 'Remove'}
            </button>
          </div>
        </div>
      ) : (
        <div className="admin-actions">
          {r.status === 'playing' && (
            <button className="btn btn-small" onClick={() => setConfirm('end')}>
              End game
            </button>
          )}
          <button className="btn btn-small btn-danger-outline" onClick={() => setConfirm('delete')}>
            Delete room
          </button>
        </div>
      )}
    </article>
  );
}

function PasswordChange({ run }: { run: Run }) {
  const [open, setOpen] = useState(false);
  const [oldPw, setOldPw] = useState('');
  const [newPw, setNewPw] = useState('');
  if (!open)
    return (
      <button className="link" onClick={() => setOpen(true)}>
        Change admin password
      </button>
    );
  return (
    <form
      className="card home-form"
      onSubmit={async (e) => {
        e.preventDefault();
        await run('ti_admin_set_password', { p_old: oldPw, p_new: newPw }, 'Password changed. Other admin devices have to unlock again.');
        setOldPw('');
        setNewPw('');
        setOpen(false);
      }}
    >
      <label>
        <span>Current password</span>
        <input type="password" value={oldPw} onChange={(e) => setOldPw(e.target.value)} autoComplete="current-password" />
      </label>
      <label>
        <span>New password (8+ characters)</span>
        <input type="password" value={newPw} onChange={(e) => setNewPw(e.target.value)} autoComplete="new-password" />
      </label>
      <button className="btn btn-primary" disabled={!oldPw || newPw.length < 8}>
        Change password
      </button>
      <button type="button" className="link" onClick={() => setOpen(false)}>
        Cancel
      </button>
    </form>
  );
}
