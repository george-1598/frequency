import { useRef, type KeyboardEvent, type PointerEvent } from 'react';

const CX = 100;
const CY = 100;
const R = 92;
const clamp = (v: number) => Math.max(0, Math.min(100, v));
/** 0 = far left, 100 = far right, along the top of the semicircle. */
const point = (v: number, r = R) => {
  const t = Math.PI * (1 - clamp(v) / 100);
  return [CX + r * Math.cos(t), CY - r * Math.sin(t)] as const;
};
const wedge = (a: number, b: number) => {
  const [x1, y1] = point(clamp(a));
  const [x2, y2] = point(clamp(b));
  return `M ${CX} ${CY} L ${x1} ${y1} A ${R} ${R} 0 0 1 ${x2} ${y2} Z`;
};

/** Target bands, outside in: 2 points, 3 points, 4 points. */
export const BANDS = [
  { span: 3, color: '#FFC857' },
  { span: 2, color: '#FF7A93' },
  { span: 1, color: '#7B61FF' },
];

export interface Needle {
  value: number;
  color: string;
  label?: string;
}

/** The dial: a semicircle with a needle you can drag; optionally the target bands and other players' needles. */
export default function Dial({
  value,
  onChange,
  target,
  needles = [],
  showMain = true,
  left,
  right,
  label = 'Dial',
}: {
  value: number;
  onChange?: (v: number) => void;
  target?: { center: number; tol: number } | null;
  /** Extra needles (other players' guesses at the reveal). */
  needles?: Needle[];
  /** Hide the main needle (e.g. the psychic only sees the target). */
  showMain?: boolean;
  left: string;
  right: string;
  label?: string;
}) {
  const ref = useRef<SVGSVGElement>(null);
  const dragging = useRef(false);
  const fromPointer = (e: PointerEvent) => {
    const box = ref.current!.getBoundingClientRect();
    const x = ((e.clientX - box.left) / box.width) * 200 - CX;
    const y = CY - ((e.clientY - box.top) / box.height) * 112;
    const angle = Math.atan2(Math.max(y, 0), x);
    onChange?.(Math.round(clamp(100 - (angle / Math.PI) * 100) * 2) / 2);
  };
  const onKey = (e: KeyboardEvent) => {
    if (!onChange) return;
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') onChange(clamp(value - (e.shiftKey ? 5 : 1)));
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') onChange(clamp(value + (e.shiftKey ? 5 : 1)));
  };
  const [nx, ny] = point(value, R - 6);

  return (
    <div className="dial">
      <svg
        ref={ref}
        viewBox="0 0 200 112"
        className={onChange ? 'dial-svg is-live' : 'dial-svg'}
        role={onChange ? 'slider' : 'img'}
        aria-label={label}
        aria-valuemin={onChange ? 0 : undefined}
        aria-valuemax={onChange ? 100 : undefined}
        aria-valuenow={onChange ? Math.round(value) : undefined}
        tabIndex={onChange ? 0 : undefined}
        onKeyDown={onKey}
        onPointerDown={(e) => {
          if (!onChange) return;
          dragging.current = true;
          (e.target as Element).setPointerCapture?.(e.pointerId);
          fromPointer(e);
        }}
        onPointerMove={(e) => dragging.current && fromPointer(e)}
        onPointerUp={() => (dragging.current = false)}
        onPointerCancel={() => (dragging.current = false)}
      >
        <defs>
          <radialGradient id="dial-face" cx="50%" cy="100%" r="100%">
            <stop offset="0" stopColor="#FFF8EC" />
            <stop offset="1" stopColor="#F4E6CF" />
          </radialGradient>
        </defs>
        <path d={`M ${CX - R - 4} ${CY} A ${R + 4} ${R + 4} 0 0 1 ${CX + R + 4} ${CY} Z`} fill="#2A2266" />
        <path d={`M ${CX - R} ${CY} A ${R} ${R} 0 0 1 ${CX + R} ${CY} Z`} fill="url(#dial-face)" />
        {/* Tick marks around the edge */}
        {Array.from({ length: 21 }, (_, i) => {
          const [x1, y1] = point(i * 5, R);
          const [x2, y2] = point(i * 5, R - (i % 5 === 0 ? 6 : 3));
          return <line key={i} x1={x1} y1={y1} x2={x2} y2={y2} stroke="#CDBA9A" strokeWidth={i % 5 === 0 ? 1.2 : 0.7} />;
        })}
        {target && BANDS.map((b) => <path key={b.span} d={wedge(target.center - target.tol * b.span, target.center + target.tol * b.span)} fill={b.color} />)}
        {needles.map((n, i) => {
          const [x, y] = point(n.value, R - 8);
          const [lx, ly] = point(n.value, R + 1);
          return (
            <g key={i}>
              <line x1={CX} y1={CY} x2={x} y2={y} stroke={n.color} strokeWidth="2.6" strokeLinecap="round" />
              <circle cx={x} cy={y} r="3" fill={n.color} />
              {n.label && (
                <text x={lx} y={ly - 2} fontSize="7" fontWeight="700" fill="#fff" textAnchor="middle" stroke="#16123A" strokeWidth="2" paintOrder="stroke">
                  {n.label}
                </text>
              )}
            </g>
          );
        })}
        {showMain && (
          <>
            <line x1={CX} y1={CY} x2={nx} y2={ny} stroke="#16123A" strokeWidth="3.4" strokeLinecap="round" />
            <circle cx={nx} cy={ny} r="3.6" fill="#16123A" />
          </>
        )}
        <circle cx={CX} cy={CY} r="9" fill="#16123A" />
        <circle cx={CX} cy={CY} r="3.4" fill="#FFC857" />
      </svg>
      <div className="dial-labels">
        <span>
          <i aria-hidden>⟵</i>
          {left || '…'}
        </span>
        <span>
          {right || '…'}
          <i aria-hidden>⟶</i>
        </span>
      </div>
    </div>
  );
}
