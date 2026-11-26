import { useState } from 'react';
import { roomLink } from '../lib/route';

/** Share the room's link (the phone's share sheet, or copy it). */
export default function ShareButton({ code, name, compact = false }: { code: string; name?: string | null; compact?: boolean }) {
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const url = roomLink(code);
  const share = async () => {
    try {
      if (navigator.share) {
        await navigator.share({ title: 'Frequency', text: `Join my Frequency game${name ? ` “${name}”` : ''}! Room code: ${code}`, url });
        return;
      }
    } catch {
      return; // share sheet closed
    }
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      setManual(true);
    }
  };
  return (
    <>
      <button className={compact ? 'btn btn-small btn-share' : 'btn btn-share'} onClick={share}>
        {!copied && <ShareIcon />}
        {copied ? 'Link copied ✓' : compact ? 'Invite' : 'Invite friends'}
      </button>
      {manual && <input className="share-manual" readOnly value={url} onFocus={(e) => e.target.select()} aria-label="Room link" />}
    </>
  );
}

/** During the game: the room code and an invite button, so friends can join any time. */
export function RoomBar({ code, name }: { code: string; name?: string | null }) {
  return (
    <div className="room-bar">
      <span className="room-bar-id">
        {name && <b>{name}</b>}
        <span>
          Code <strong>{code}</strong>
        </span>
      </span>
      <ShareButton code={code} name={name} compact />
    </div>
  );
}

/** The classic share icon: three connected dots. */
function ShareIcon() {
  return (
    <svg className="share-icon" viewBox="0 0 24 24" width="18" height="18" aria-hidden>
      <circle cx="18" cy="5" r="3" fill="currentColor" />
      <circle cx="6" cy="12" r="3" fill="currentColor" />
      <circle cx="18" cy="19" r="3" fill="currentColor" />
      <line x1="8.6" y1="10.5" x2="15.4" y2="6.5" stroke="currentColor" strokeWidth="2" />
      <line x1="8.6" y1="13.5" x2="15.4" y2="17.5" stroke="currentColor" strokeWidth="2" />
    </svg>
  );
}
