import { call } from './supabase';
import { ALL_SUGGESTIONS } from './examples';

export type Suggestion = { left: string; right: string; clue: string };

/** The 🎲 deck, from the database (the admin can edit it); the built-in list until it loads or if it can't. */
let deck: Suggestion[] = ALL_SUGGESTIONS;
let loading: Promise<void> | null = null;

export function loadSuggestions() {
  loading ??= call<Suggestion[]>('ti_suggestions')
    .then((d) => {
      if (Array.isArray(d) && d.length) deck = d;
    })
    .catch(() => {
      loading = null; // try again next time
    });
  return loading;
}

export const suggestions = () => deck;
export const randomSuggestion = (except?: string): Suggestion => {
  const pool = except ? deck.filter((s) => s.clue !== except) : deck;
  return pool[Math.floor(Math.random() * pool.length)] ?? ALL_SUGGESTIONS[0];
};
