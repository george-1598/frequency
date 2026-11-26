import { useRef, type KeyboardEvent, type PointerEvent } from 'react';

const CX = 100;
const CY = 100;
const R = 92;
// Room above the arc for the players' initials.
const VB_TOP = -10;
const VB_H = 122;
const clamp = (v: number) => Math.max(0, Math.min(100, v));
/** 0 = far left, 100 = far right, along the top of the semicircle. */
const angleOf = (v: number) => Math.PI * (1 - clamp(v) / 100);
const point = (v: number, r = R) => {
  const t = angleOf(v);
  return [CX + r * Math.cos(t), CY - r * Math.sin(t)] as const;
};
const wedge = (a: number, b: number) => {
  const [x1, y1] = point(clamp(a));
  const [x2, y2] = point(clamp(b));
  return `M ${CX} ${CY} L ${x1} ${y1} A ${R} ${R} 0 0 1 ${x2} ${y2} Z`;
};

/** Target bands, outside in: yellow (2 points), orange (3), blue (4). */
export const BANDS = [
  { span: 3, color: '#F2B84B' },
  { span: 2, color: '#F0713E' },
  { span: 1, color: '#4A90C2' },
];

export interface Needle {
  value: number;
  color: string;
  label?: string;
}

/** Group labelled needles within 4 points of each other into one label. */
function labelGroups(needles: Needle[]): { value: number; label: string }[] {
  const sorted = needles.filter((n) => n.label).sort((a, b) => a.value - b.value);
  const groups: { values: number[]; labels: string[] }[] = [];
  for (const n of sorted) {
    const last = groups[groups.length - 1];
    if (last && n.value - last.values[last.values.length - 1] < 4) {
      last.values.push(n.value);
      last.labels.push(n.label!);
    } else groups.push({ values: [n.value], labels: [n.label!] });
  }
  return groups.map((g) => ({ value: g.values.reduce((a, b) => a + b, 0) / g.values.length, label: g.labels.join('·') }));
}

/** A needle with a pointy arrow tip. */
function Arrow({ value, color, width = 3.2, length = R - 4 }: { value: number; color: string; width?: number; length?: number }) {
  const t = angleOf(value);
  const ux = Math.cos(t);
  const uy = -Math.sin(t);
  const px = -uy; // perpendicular
  const py = ux;
  const tipX = CX + ux * length;
  const tipY = CY + uy * length;
  const head = 13;
  const half = 5.2;
  const bx = CX + ux * (length - head);
  const by = CY + uy * (length - head);
  return (
    <g>
      <line x1={CX} y1={CY} x2={bx + ux * 1} y2={by + uy * 1} stroke={color} strokeWidth={width} strokeLinecap="round" />
      <polygon points={`${tipX},${tipY} ${bx + px * half},${by + py * half} ${bx - px * half},${by - py * half}`} fill={color} strokeLinejoin="round" />
    </g>
  );
}

/** The dial: a semicircle with a draggable needle; optionally the target bands and other players' needles. */
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
  needles?: Needle[];
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
    const y = CY - (VB_TOP + ((e.clientY - box.top) / box.height) * VB_H);
    const a = Math.atan2(Math.max(y, 0), x);
    onChange?.(Math.round(clamp(100 - (a / Math.PI) * 100) * 2) / 2);
  };
  const onKey = (e: KeyboardEvent) => {
    if (!onChange) return;
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') onChange(clamp(value - (e.shiftKey ? 5 : 1)));
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') onChange(clamp(value + (e.shiftKey ? 5 : 1)));
  };

  return (
    <div className="dial">
      <svg
        ref={ref}
        viewBox={`0 ${VB_TOP} 200 ${VB_H}`}
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
        <path d={`M ${CX - R} ${CY} A ${R} ${R} 0 0 1 ${CX + R} ${CY} Z`} fill="#F3EAD8" />
        {target && BANDS.map((b) => <path key={b.span} d={wedge(target.center - target.tol * b.span, target.center + target.tol * b.span)} fill={b.color} />)}
        {needles.map((n, i) => (
          <Arrow key={i} value={n.value} color={n.color} width={2.6} length={R - 8} />
        ))}
        {/* Initials above the needles; needles that land close together share one label ("B·C"). */}
        {labelGroups(needles).map((g, i) => {
          const [lx, ly] = point(g.value, R + 2);
          return (
            <text key={i} x={lx} y={ly - 2} fontSize="7.5" fontWeight="700" fill="#2b2420" textAnchor="middle" stroke="#fffdf8" strokeWidth="2.4" paintOrder="stroke">
              {g.label}
            </text>
          );
        })}
        {showMain && <Arrow value={value} color="#C8102E" />}
        <circle cx={CX} cy={CY} r="8.5" fill="#7A231C" />
        <circle cx={CX} cy={CY} r="3.4" fill="#F3EAD8" />
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
