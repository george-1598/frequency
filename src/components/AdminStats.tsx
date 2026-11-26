import { useEffect, useState } from 'react';
import { call } from '../lib/supabase';
import { Stat } from './Admin';

interface Stats {
  games: number;
  finished: number;
  rounds: number;
  games_week: number;
  avg_players: number | null;
  by_day: { day: string; games: number }[];
  top_scales: { left: string; right: string; uses: number }[];
  recent: { room: string; started_at: string; finished_at: string | null; rounds: number; players: number }[];
}

const when = (iso: string) =>
  new Date(iso).toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const mins = (a: string, b: string) => Math.max(1, Math.round((new Date(b).getTime() - new Date(a).getTime()) / 60000));

/** Games over time, kept even after rooms are deleted. */
export default function AdminStats() {
  const [s, setS] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    call<Stats>('ti_admin_stats').then(setS, (e) => setError(e instanceof Error ? e.message : 'Could not load'));
  }, []);
  if (!s) return <p className="loading">{error ?? 'Loading history…'}</p>;
  const max = Math.max(1, ...s.by_day.map((d) => d.games));
  return (
    <>
      <div className="admin-stats admin-stats--3">
        <Stat n={s.games} label="games played" />
        <Stat n={s.rounds} label="rounds played" />
        <Stat n={s.games_week} label="games this week" />
        <Stat n={s.finished} label="played to the end" />
        <Stat n={s.avg_players ?? '–'} label="players per game" />
        <Stat n={s.games ? Math.round(s.rounds / s.games) : 0} label="rounds per game" />
      </div>

      <div className="card">
        <h3>Games per day</h3>
        <div className="admin-bars" role="img" aria-label="Games per day over the last two weeks">
          {s.by_day.map((d) => (
            <div key={d.day} className="admin-bar" title={`${d.day}: ${d.games}`}>
              <span className="admin-bar-n">{d.games || ''}</span>
              <i style={{ height: `${(d.games / max) * 100}%` }} />
              <span className="admin-bar-day">{new Date(d.day).getDate()}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="card">
        <h3>Most played scales</h3>
        {s.top_scales.length === 0 ? (
          <p className="muted">No rounds yet.</p>
        ) : (
          <ol className="admin-top">
            {s.top_scales.map((t) => (
              <li key={`${t.left}|${t.right}`}>
                <span>
                  {t.left} ⟷ {t.right}
                </span>
                <b>{t.uses}×</b>
              </li>
            ))}
          </ol>
        )}
      </div>

      <div className="card">
        <h3>Recent games</h3>
        <ul className="admin-recent">
          {s.recent.map((g, i) => (
            <li key={i}>
              <strong>{g.room}</strong>
              <span>{when(g.started_at)}</span>
              <span className="muted">
                {g.players} player{g.players === 1 ? '' : 's'} · {g.rounds} round{g.rounds === 1 ? '' : 's'}
                {g.finished_at ? ` · ${mins(g.started_at, g.finished_at)} min` : ' · not finished'}
              </span>
            </li>
          ))}
        </ul>
        <small className="muted">History starts today; games before this weren’t recorded.</small>
      </div>
    </>
  );
}
