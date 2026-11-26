# Frequency

A party game for phones. Each round one player — the **creator** — sets up a
scale (like *Cold ⟷ Hot*), drags the needle to a secret spot, picks how precise
it has to be, and writes a clue (or rolls 🎲 for a suggestion). Everyone else
drags their needle to where they think the clue sits. Closest wins the most points.

**Play:** https://george-1598.github.io/frequency/

- Rooms with a 5-letter code or share link; 2–12 players, no accounts.
- Live on every phone (Supabase Realtime); the server keeps the target and the
  guesses secret until the reveal.
- 100 built-in scales, plus your own per room.
- Scoring: middle band 4, then 3, then 2; the creator gets the guessers' average.

## Stack

Vite + React + TypeScript on GitHub Pages, Supabase (Postgres functions,
anonymous auth, Realtime). The database schema and all game rules live in
`supabase/migrations/`; apply them with `scripts/sql.sh`.
