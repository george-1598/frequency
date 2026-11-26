import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { call } from '../lib/supabase';

interface DeckItem {
  id: number;
  left: string;
  right: string;
  clue: string;
  hidden: boolean;
  source: 'builtin' | 'player' | 'admin';
}
interface Pending {
  id: number;
  left: string;
  right: string;
  clue: string;
  by: string | null;
  uses: number;
  last_at: string;
  new_scale: boolean;
}
type Scale = { left: string; right: string; clue: string };
type Filter = 'all' | 'added' | 'hidden';
const PAGE = 30;

/** Players' new scales to review, and the 🎲 suggestion deck. */
export default function AdminScales({ onChanged }: { onChanged: () => void }) {
  const [data, setData] = useState<{ deck: DeckItem[]; pending: Pending[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [limit, setLimit] = useState(PAGE);
  const [adding, setAdding] = useState(false);

  const load = useCallback(async () => {
    try {
      setData(await call('ti_admin_deck'));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load');
    }
  }, []);
  useEffect(() => void load(), [load]);

  /** Run an action; true if it worked. */
  const run = async (fn: string, args: Record<string, unknown>, done?: string) => {
    setError(null);
    try {
      await call(fn, args);
      setNotice(done ?? null);
      await load();
      onChanged();
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
      return false;
    }
  };

  if (!data) return <p className="loading">{error ?? 'Loading scales…'}</p>;
  const q = query.trim().toLowerCase();
  const matches = data.deck.filter(
    (d) =>
      (filter === 'all' || (filter === 'hidden' ? d.hidden : d.source !== 'builtin')) &&
      (!q || `${d.left} ${d.right} ${d.clue}`.toLowerCase().includes(q)),
  );
  const visible = data.deck.filter((d) => !d.hidden).length;

  return (
    <>
      {notice && (
        <p className="admin-notice" onClick={() => setNotice(null)}>
          {notice}
        </p>
      )}
      {error && <p className="error">{error}</p>}

      <div className="card admin-section">
        <h3>
          From players <small>{data.pending.length}</small>
        </h3>
        {data.pending.length === 0 ? (
          <p className="muted">
            Nothing new. When a creator writes a scale or clue that isn’t in the deck, it shows up here for you to add or remove.
          </p>
        ) : (
          <ul className="admin-scale-list">
            {data.pending.map((p) => (
              <PendingRow key={p.id} p={p} run={run} />
            ))}
          </ul>
        )}
      </div>

      <div className="card admin-section">
        <div className="admin-section-head">
          <h3>
            Suggestion deck <small>{visible} in use</small>
          </h3>
          {!adding && (
            <button className="btn btn-small" onClick={() => setAdding(true)}>
              + Add
            </button>
          )}
        </div>
        {adding && (
          <ScaleForm
            initial={{ left: '', right: '', clue: '' }}
            submit="Add to the deck"
            onCancel={() => setAdding(false)}
            onSave={async (s) => {
              if (await run('ti_admin_deck_save', { p_id: null, p_left: s.left, p_right: s.right, p_clue: s.clue }, 'Added to the deck.'))
                setAdding(false);
            }}
          />
        )}
        <input
          className="admin-search"
          type="search"
          value={query}
          onChange={(e) => (setQuery(e.target.value), setLimit(PAGE))}
          placeholder="Search scales and clues"
        />
        <div className="seg admin-filter">
          {(['all', 'added', 'hidden'] as Filter[]).map((f) => (
            <button key={f} aria-pressed={filter === f} onClick={() => (setFilter(f), setLimit(PAGE))}>
              {f === 'all' ? `All (${data.deck.length})` : f === 'added' ? 'Added' : 'Hidden'}
            </button>
          ))}
        </div>
        <ul className="admin-scale-list">
          {matches.slice(0, limit).map((d) => (
            <DeckRow key={d.id} d={d} run={run} />
          ))}
        </ul>
        {matches.length === 0 && <p className="muted center-text">No scales match.</p>}
        {matches.length > limit && (
          <button className="link" onClick={() => setLimit((l) => l + PAGE)}>
            Show more ({matches.length - limit} left)
          </button>
        )}
      </div>
    </>
  );
}

type Run = (fn: string, args: Record<string, unknown>, done?: string) => Promise<boolean>;

function PendingRow({ p, run }: { p: Pending; run: Run }) {
  const [editing, setEditing] = useState(false);
  const accept = (s: Scale) => run('ti_admin_submission_accept', { p_id: p.id, p_left: s.left, p_right: s.right, p_clue: s.clue }, 'Added to the deck.');
  if (editing)
    return (
      <li className="admin-scale is-editing">
        <ScaleForm initial={p} submit="Add to the deck" onCancel={() => setEditing(false)} onSave={(s) => void accept(s)} />
      </li>
    );
  return (
    <li className="admin-scale">
      <ScaleText s={p} />
      <p className="admin-scale-meta">
        <span className={`admin-tag${p.new_scale ? ' is-new' : ''}`}>{p.new_scale ? 'New scale' : 'New clue'}</span>
        {p.by ? `by ${p.by}` : ''}
        {p.uses > 1 ? ` · used ${p.uses} times` : ''}
      </p>
      <div className="admin-actions">
        <button className="btn btn-small btn-danger-outline" onClick={() => run('ti_admin_submission_dismiss', { p_id: p.id }, 'Removed.')}>
          Remove
        </button>
        <button className="btn btn-small" onClick={() => setEditing(true)}>
          Edit
        </button>
        <button className="btn btn-small btn-primary" onClick={() => void accept(p)}>
          Add to deck
        </button>
      </div>
    </li>
  );
}

function DeckRow({ d, run }: { d: DeckItem; run: Run }) {
  const [mode, setMode] = useState<null | 'edit' | 'delete'>(null);
  if (mode === 'edit')
    return (
      <li className="admin-scale is-editing">
        <ScaleForm
          initial={d}
          submit="Save"
          onCancel={() => setMode(null)}
          onSave={async (s) => {
            if (await run('ti_admin_deck_save', { p_id: d.id, p_left: s.left, p_right: s.right, p_clue: s.clue }, 'Saved.')) setMode(null);
          }}
        />
      </li>
    );
  return (
    <li className={`admin-scale${d.hidden ? ' is-hidden' : ''}`}>
      <ScaleText s={d} />
      {(d.hidden || d.source !== 'builtin') && (
        <p className="admin-scale-meta">
          {d.hidden && <span className="admin-tag">Hidden</span>}
          {d.source === 'player' && <span className="admin-tag is-new">From a player</span>}
          {d.source === 'admin' && <span className="admin-tag is-new">Added by you</span>}
        </p>
      )}
      {mode === 'delete' ? (
        <div className="admin-confirm-box">
          <span>Delete this one for good? (Hiding keeps it, just out of the suggestions.)</span>
          <div>
            <button className="btn btn-small" onClick={() => setMode(null)}>
              Cancel
            </button>
            <button className="btn btn-small btn-danger" onClick={() => void run('ti_admin_deck_delete', { p_id: d.id }, 'Deleted.')}>
              Delete
            </button>
          </div>
        </div>
      ) : (
        <div className="admin-actions">
          <button className="btn btn-small btn-danger-outline" onClick={() => setMode('delete')}>
            Delete
          </button>
          <button
            className="btn btn-small"
            onClick={() => run('ti_admin_deck_hide', { p_id: d.id, p_hidden: !d.hidden }, d.hidden ? 'Back in the suggestions.' : 'Hidden from the suggestions.')}
          >
            {d.hidden ? 'Show' : 'Hide'}
          </button>
          <button className="btn btn-small" onClick={() => setMode('edit')}>
            Edit
          </button>
        </div>
      )}
    </li>
  );
}

function ScaleText({ s }: { s: Scale }) {
  return (
    <div className="admin-scale-text">
      <span className="admin-scale-ends">
        {s.left} <i>⟷</i> {s.right}
      </span>
      <span className="admin-scale-clue">“{s.clue}”</span>
    </div>
  );
}

function ScaleForm({ initial, submit, onSave, onCancel }: { initial: Scale; submit: string; onSave: (s: Scale) => void; onCancel: () => void }) {
  const [s, setS] = useState<Scale>({ left: initial.left, right: initial.right, clue: initial.clue });
  const save = (e: FormEvent) => {
    e.preventDefault();
    onSave(s);
  };
  return (
    <form className="admin-scale-form" onSubmit={save}>
      <div className="editor-row">
        <label>
          <span>Left end</span>
          <input value={s.left} onChange={(e) => setS({ ...s, left: e.target.value })} maxLength={40} />
        </label>
        <label>
          <span>Right end</span>
          <input value={s.right} onChange={(e) => setS({ ...s, right: e.target.value })} maxLength={40} />
        </label>
      </div>
      <label>
        <span>Clue</span>
        <input value={s.clue} onChange={(e) => setS({ ...s, clue: e.target.value })} maxLength={80} />
      </label>
      <div className="admin-actions">
        <button type="button" className="btn btn-small" onClick={onCancel}>
          Cancel
        </button>
        <button className="btn btn-small btn-primary" disabled={!s.left.trim() || !s.right.trim() || !s.clue.trim()}>
          {submit}
        </button>
      </div>
    </form>
  );
}
