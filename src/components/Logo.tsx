/** Frequency's mark: the game's dial (bands and a pointy needle) on dark red. */
export function LogoMark({ size = 40 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden className="logo-mark">
      <rect width="64" height="64" rx="15" fill="#7A231C" />
      <path d="M8 44 A24 24 0 0 1 56 44 Z" fill="#F3EAD8" />
      <path d="M32 44 L27.50 20.43 A24 24 0 0 1 55.25 38.03 Z" fill="#F2B84B" />
      <path d="M32 44 L33.51 20.05 A24 24 0 0 1 53.03 32.44 Z" fill="#F0713E" />
      <path d="M32 44 L39.42 21.17 A24 24 0 0 1 49.50 27.57 Z" fill="#4A90C2" />
      <line x1="32" y1="44" x2="41.46" y2="30.97" stroke="#C8102E" strokeWidth="2.6" strokeLinecap="round" />
      <polygon points="44.93,26.20 43.38,33.11 38.85,29.81" fill="#C8102E" />
      <circle cx="32" cy="44" r="4.6" fill="#2B2420" />
      <circle cx="32" cy="44" r="1.8" fill="#F3EAD8" />
    </svg>
  );
}

export default function Logo({ size = 22 }: { size?: number }) {
  return (
    <span className="logo">
      <LogoMark size={size} />
      <span className="logo-word">Frequency</span>
    </span>
  );
}
