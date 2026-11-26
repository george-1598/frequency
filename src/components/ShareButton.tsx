import { useState } from 'react';
import { roomLink } from '../lib/route';

/** Share the room's link (the phone's share sheet, or copy it). */
export default function ShareButton({ code, compact = false }: { code: string; compact?: boolean }) {
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const url = roomLink(code);
  const share = async () => {
    try {
      if (navigator.share) {
        await navigator.share({ title: 'Frequency', text: `Join my Frequency game! Room code: ${code}`, url });
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
        {copied ? 'Link copied ✓' : compact ? '📤 Invite' : '📤 Invite friends'}
      </button>
      {manual && <input className="share-manual" readOnly value={url} onFocus={(e) => e.target.select()} aria-label="Room link" />}
    </>
  );
}

/** During the game: the room code and an invite button, so friends can join any time. */
export function RoomBar({ code }: { code: string }) {
  return (
    <div className="room-bar">
      <span>
        Room <strong>{code}</strong>
      </span>
      <ShareButton code={code} compact />
    </div>
  );
}
