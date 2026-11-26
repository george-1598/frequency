-- The suggestion deck moves into the database (the admin can edit it), new
-- scales players write are kept for review, and a small game log for stats.

-- ---------------------------------------------------------------- deck
create table if not exists public.ti_deck (
  id bigint generated always as identity primary key,
  left_label text not null check (length(left_label) between 1 and 40),
  right_label text not null check (length(right_label) between 1 and 40),
  clue text not null check (length(clue) between 1 and 80),
  hidden boolean not null default false,
  source text not null default 'builtin' check (source in ('builtin', 'player', 'admin')),
  created_at timestamptz not null default now()
);
create unique index if not exists ti_deck_unique on public.ti_deck (lower(left_label), lower(right_label), lower(clue));
alter table public.ti_deck enable row level security;

insert into public.ti_deck (left_label, right_label, clue) values
  ('Quiet place', 'Loud place', 'A library on a Sunday morning'),
  ('Naughty', 'Nice', 'Eating the last slice without asking'),
  ('Cold', 'Hot', 'A mug of mulled wine'),
  ('Worst Christmas song', 'Best Christmas song', 'Last Christmas'),
  ('Overrated film', 'Underrated film', 'Love Actually'),
  ('Easy to wrap', 'Impossible to wrap', 'A bicycle'),
  ('Healthy', 'Unhealthy', 'A big slice of cake'),
  ('Cheap date', 'Fancy date', 'A picnic in the park'),
  ('Unromantic', 'Romantic', 'Watching football together'),
  ('Calm', 'Chaos', 'A kitchen while baking cookies'),
  ('Useless gift', 'Perfect gift', 'Fluffy socks'),
  ('Scary', 'Cozy', 'A snowstorm outside the window'),
  ('Childish', 'Grown-up', 'Building a snowman'),
  ('Terrible singer', 'Amazing singer', 'Me singing in the car'),
  ('Morning person', 'Night owl', 'A teenager on holiday'),
  ('Never', 'All the time', 'Checking my phone'),
  ('Bad idea', 'Great idea', 'A tattoo of your partner’s name'),
  ('Boring', 'Exciting', 'Untangling Christmas lights'),
  ('Tiny', 'Huge', 'A hamster'),
  ('Slow', 'Fast', 'A sloth on roller skates'),
  ('Old-fashioned', 'Trendy', 'Writing letters by hand'),
  ('Easy', 'Hard', 'Assembling flat-pack furniture'),
  ('Dangerous', 'Safe', 'Skydiving'),
  ('Smells bad', 'Smells great', 'Fresh bread'),
  ('Lazy', 'Exhausting', 'Moving house'),
  ('Mild', 'Spicy', 'Ketchup'),
  ('Relaxing', 'Stressful', 'A family dinner'),
  ('Villain', 'Hero', 'The Grinch'),
  ('Indoor', 'Outdoor', 'Table tennis'),
  ('Forgettable', 'Unforgettable', 'Your first kiss'),
  ('Waste of money', 'Worth every penny', 'A good mattress'),
  ('Cringe', 'Cool', 'Socks with sandals'),
  ('Rude', 'Polite', 'Leaving a group chat'),
  ('Beginner', 'Expert', 'Me at cooking'),
  ('Normal pet', 'Unusual pet', 'A tarantula'),
  ('Bad superpower', 'Great superpower', 'Talking to fish'),
  ('Tastes bad', 'Tastes great', 'Pineapple on pizza'),
  ('Background character', 'Main character', 'The person who always has snacks'),
  ('Junk food', 'Gourmet food', 'Sushi from a petrol station'),
  ('Ancient', 'Futuristic', 'A fax machine'),
  ('Quiet', 'Loud', 'A library on a Sunday morning'),
  ('Cheap', 'Expensive', 'A cinema ticket'),
  ('Overrated', 'Underrated', 'Brunch'),
  ('Bad gift', 'Great gift', 'Fluffy socks'),
  ('Cozy', 'Scary', 'A snowstorm outside the window'),
  ('Calm', 'Chaotic', 'A kitchen while baking cookies'),
  ('Ugly', 'Beautiful', 'A pug'),
  ('Useless', 'Essential', 'A phone charger'),
  ('Sad song', 'Happy song', 'Hey Jude'),
  ('Bad film', 'Great film', 'Titanic'),
  ('Weird food', 'Normal food', 'Pineapple on pizza'),
  ('Rare', 'Common', 'A four-leaf clover'),
  ('Lazy activity', 'Exhausting activity', 'Moving house'),
  ('Morning thing', 'Night thing', 'Brushing your teeth'),
  ('Soft', 'Hard', 'An avocado'),
  ('Sweet', 'Savoury', 'Popcorn'),
  ('Bad habit', 'Good habit', 'Biting your nails'),
  ('Introvert activity', 'Extrovert activity', 'Karaoke'),
  ('Summer', 'Winter', 'Ice cream'),
  ('Underdressed', 'Overdressed', 'A suit at a barbecue'),
  ('Simple', 'Complicated', 'Tax returns'),
  ('Worst holiday food', 'Best holiday food', 'Fruitcake'),
  ('Low effort gift', 'High effort gift', 'A gift card'),
  ('Bad idea at a party', 'Great idea at a party', 'Bringing a guitar'),
  ('Fragile', 'Indestructible', 'An old Nokia phone'),
  ('Dirty', 'Clean', 'A teenager’s bedroom'),
  ('Unknown', 'Famous', 'Your local baker'),
  ('Fiction', 'Real', 'The Loch Ness monster'),
  ('Silent', 'Noisy hobby', 'Knitting'),
  ('Mundane', 'Magical', 'The northern lights'),
  ('Short-lived', 'Lasts forever', 'A New Year’s resolution'),
  ('Hated chore', 'Loved chore', 'Ironing'),
  ('Cat person thing', 'Dog person thing', 'Going for a run'),
  ('Ordinary', 'Luxurious', 'A bubble bath'),
  ('Easy to learn', 'Hard to learn', 'Juggling'),
  ('Sounds made up', 'Sounds real', 'A platypus'),
  ('Peaceful', 'Violent', 'A pillow fight'),
  ('Underground', 'Mainstream', 'Vinyl records'),
  ('Plain', 'Fancy', 'Toast with butter'),
  ('Wet', 'Dry', 'A cat after a bath'),
  ('Harmless', 'Deadly', 'A jellyfish'),
  ('Square', 'Round', 'A pizza box'),
  ('Dark', 'Bright', 'A cinema during the film'),
  ('Sour', 'Sweet', 'A lemon tart'),
  ('Scary film', 'Feel-good film', 'Home Alone'),
  ('Lame party', 'Legendary party', 'An office party'),
  ('Basic', 'Exotic', 'Dragon fruit'),
  ('Mild weather', 'Extreme weather', 'A November day'),
  ('Light', 'Heavy', 'A duvet'),
  ('Bad at hiding', 'Good at hiding', 'A toddler playing hide-and-seek'),
  ('Low stakes', 'High stakes', 'Choosing a restaurant'),
  ('Unpopular opinion', 'Popular opinion', 'Winter is the best season'),
  ('Needs no skill', 'Needs lots of skill', 'Parallel parking'),
  ('Smooth', 'Rough', 'A cat’s tongue'),
  ('Bad first date', 'Great first date', 'Bowling'),
  ('Grandma would hate it', 'Grandma would love it', 'A nose piercing'),
  ('Cheap thrill', 'Once in a lifetime', 'Seeing a shooting star'),
  ('Everyday item', 'Collector''s item', 'A Pokémon card'),
  ('Socially awkward', 'Smooth talker', 'Me at a wedding'),
  ('Normal Tuesday', 'Best day ever', 'A snow day off school'),
  ('Bad smell', 'Good smell', 'A wet dog'),
  ('Sleepy', 'Energetic', 'A cat at 3 am'),
  ('Unhelpful', 'Helpful', 'Autocorrect'),
  ('Tacky decoration', 'Classy decoration', 'An inflatable Santa'),
  ('Overcooked', 'Undercooked', 'A medium-rare steak'),
  ('Gentle', 'Fierce', 'A goose'),
  ('Snack', 'Meal', 'A bowl of cereal'),
  ('Short trip', 'Long trip', 'A weekend in Vienna'),
  ('Unlucky', 'Lucky', 'Finding money in old jeans'),
  ('Mess', 'Masterpiece', 'My handwriting'),
  ('Not romantic', 'Very romantic', 'Breakfast in bed'),
  ('Red flag', 'Green flag', 'Texting back instantly'),
  ('Dealbreaker', 'Dream partner', 'Snoring'),
  ('Low effort', 'High effort', 'A handwritten love letter'),
  ('Awkward first date', 'Perfect first date', 'Mini golf'),
  ('Too soon', 'Perfect timing', 'Saying “I love you” after a month'),
  ('Cringey pet name', 'Cute pet name', '“Babe”'),
  ('Unforgivable', 'Easily forgiven', 'Forgetting an anniversary'),
  ('Couple goals', 'Couple fail', 'Matching outfits'),
  ('Only friends do it', 'Only couples do it', 'Sharing a dessert'),
  ('Boring night in', 'Perfect night in', 'Takeaway and a film'),
  ('Keep it private', 'Share with everyone', 'Posting couple selfies'),
  ('Totally chill', 'Very jealous', 'Your partner liking an ex’s photo'),
  ('Terrible gift for a partner', 'Perfect gift for a partner', 'A vacuum cleaner'),
  ('Rarely', 'Constantly', 'Saying “I’m fine” when you’re not'),
  ('Easy to agree on', 'Impossible to agree on', 'Where to eat tonight'),
  ('Unattractive habit', 'Attractive habit', 'Cooking for someone'),
  ('Clingy', 'Independent', 'Texting goodnight every night'),
  ('Great first-date topic', 'Never on a first date', 'Your ex'),
  ('Small gesture', 'Grand gesture', 'Flowers for no reason'),
  ('Starts a fight', 'Ends a fight', '“We need to talk”'),
  ('Sweet', 'Way over the top', 'A proposal on the big screen at a match'),
  ('Boring couple activity', 'Fun couple activity', 'Grocery shopping together'),
  ('Minor annoyance', 'Relationship ender', 'Dishes left in the sink'),
  ('Easy to say', 'Hard to say', '“Sorry”'),
  ('Just friends', 'Soulmates', 'Best friends for ten years'),
  ('Hates surprises', 'Loves surprises', 'Me'),
  ('Unromantic place', 'Romantic place', 'IKEA'),
  ('Bad advice', 'Great advice', '“Never go to bed angry”'),
  ('Lazy Sunday', 'Adventurous Sunday', 'A long walk together'),
  ('Least important in a partner', 'Most important in a partner', 'A sense of humour'),
  ('Petty argument', 'Serious argument', 'Who ate the last biscuit'),
  ('Cheesy line', 'Smooth line', '“Are you a magician?”'),
  ('Happy to share', 'Never sharing', 'My fries'),
  ('Weird thing couples do', 'Normal thing couples do', 'Giving each other nicknames'),
  ('Always forgets', 'Never forgets', 'Our anniversary'),
  ('Wouldn’t do it for love', 'Would do it for love', 'Moving to another country'),
  ('Sweet', 'Too much', 'Five good-morning texts'),
  ('Fleeting crush', 'True love', 'A holiday romance'),
  ('Embarrassing', 'Adorable', 'Singing to your partner in public'),
  ('Least romantic month', 'Most romantic month', 'February'),
  ('Doesn’t matter', 'Matters a lot', 'Who pays on a first date'),
  ('Terrible cook', 'Master chef', 'My partner'),
  ('Bad listener', 'Great listener', 'Me when football is on'),
  ('Low-key', 'Extra', 'A surprise birthday party'),
  ('Turn-off', 'Charming', 'Being rude to waiters'),
  ('Ruins a friendship', 'Builds a friendship', 'A road trip together'),
  ('Easy to keep', 'Impossible to keep', 'A secret from your partner'),
  ('No big deal', 'Huge deal', 'Meeting the parents'),
  ('Grumpy', 'Cuddly', 'Me in the morning'),
  ('Bad at texting', 'Great at texting', 'Replying with “k”'),
  ('Total stranger', 'Basically family', 'My partner’s best friend'),
  ('Annoying', 'Endearing', 'Stealing the duvet'),
  ('Wild night out', 'Cosy evening', 'A double date'),
  ('Boring date idea', 'Creative date idea', 'A cooking class'),
  ('Never', 'Every single day', 'Saying “I love you”'),
  ('Bad relationship advice', 'Good relationship advice', '“Keep score”'),
  ('Forgettable moment', 'Unforgettable moment', 'Our first trip together'),
  ('Easy chore to share', 'Chore worth fighting over', 'Taking out the bins'),
  ('White lie', 'Big lie', '“I love the jumper you knitted”'),
  ('Needs no reason', 'Needs a big reason', 'Buying flowers'),
  ('Not cute', 'Very cute', 'An old couple holding hands'),
  ('Bad for a relationship', 'Good for a relationship', 'Separate hobbies'),
  ('Reply instantly', 'Leave on read', 'A meme at 2 am'),
  ('Relaxing trip together', 'Stressful trip together', 'Camping'),
  ('Every day', 'Special occasions only', 'Wearing your best perfume'),
  ('Anti-romance film', 'Romance film', 'The Notebook'),
  ('Spontaneous', 'Carefully planned', 'A weekend getaway'),
  ('Totally private', 'Public display of affection', 'Holding hands'),
  ('Easy to impress', 'Hard to impress', 'Your partner’s mum'),
  ('Small talk', 'Deep talk', '“Do you want kids one day?”'),
  ('Cute couple habit', 'Annoying couple habit', 'Finishing each other’s sentences'),
  ('Calm animal', 'Chaotic animal', 'A raccoon'),
  ('Silly', 'Serious', 'A tie with ducks on it'),
  ('Wallflower', 'Life of the party', 'My uncle at weddings'),
  ('Underrated snack', 'Overrated snack', 'Avocado toast'),
  ('Worst season', 'Best season', 'Autumn'),
  ('Cheap holiday', 'Dream holiday', 'A week in Iceland'),
  ('Bad pet name', 'Great pet name', 'Mr. Whiskers'),
  ('Overpriced', 'Bargain', 'Water at the airport'),
  ('Easy to draw', 'Hard to draw', 'A horse'),
  ('Hidden talent', 'Obvious talent', 'Whistling'),
  ('Guilty pleasure', 'Proud pleasure', 'Reality TV'),
  ('Sounds tasty', 'Sounds disgusting', 'Pickle ice cream'),
  ('Kids love it', 'Adults love it', 'Brussels sprouts'),
  ('Pointless invention', 'Life-changing invention', 'The selfie stick'),
  ('Normal Saturday', 'Perfect Saturday', 'Sleeping until noon'),
  ('Weak', 'Strong', 'An espresso'),
  ('Homebody', 'Globetrotter', 'A tortoise'),
  ('Calm job', 'Stressful job', 'Air traffic controller'),
  ('Boring job', 'Dream job', 'Professional taste tester'),
  ('Useless skill', 'Useful skill', 'Speaking Latin'),
  ('Cheap hobby', 'Expensive hobby', 'Golf'),
  ('Boring to watch', 'Thrilling to watch', 'Curling'),
  ('Morning drink', 'Evening drink', 'Hot chocolate'),
  ('Soft-spoken', 'Very loud', 'A drill sergeant'),
  ('Not scary', 'Terrifying', 'A clown at night'),
  ('Cute animal', 'Ugly animal', 'A naked mole rat'),
  ('Ordinary sandwich', 'Legendary sandwich', 'A cheese toastie'),
  ('Easy to pronounce', 'Hard to pronounce', 'Worcestershire'),
  ('Myth', 'Fact', 'Goldfish have a three-second memory'),
  ('Only tasty at 3 am', 'Tasty any time', 'Cold pizza'),
  ('Calming sound', 'Annoying sound', 'A ticking clock'),
  ('Classy drink', 'Trashy drink', 'Boxed wine'),
  ('Useless app', 'Essential app', 'A torch app'),
  ('Normal fear', 'Weird fear', 'Fear of buttons'),
  ('Too short', 'Too long', 'A three-hour film'),
  ('Bad gift for a boss', 'Good gift for a boss', 'A mug'),
  ('Overrated city', 'Underrated city', 'Paris'),
  ('Weird collection', 'Normal collection', 'Collecting spoons'),
  ('Timeless', 'Dated', 'Skinny jeans'),
  ('Annoying song', 'Great song', 'Baby Shark'),
  ('Kid-friendly', 'Adults only', 'A water park'),
  ('Bad picnic weather', 'Perfect picnic weather', 'A light drizzle'),
  ('Smells like childhood', 'Smells like adulthood', 'Crayons'),
  ('Rarely used', 'Used every day', 'The dishwasher'),
  ('Boring holiday', 'Exciting holiday', 'A cruise'),
  ('Easy to forget', 'Hard to forget', 'The Wi-Fi password'),
  ('Good in theory', 'Good in practice', 'The gym at 6 am'),
  ('Clumsy', 'Athletic', 'Me at bowling'),
  ('Underpaid', 'Overpaid', 'Footballers'),
  ('Tasty combo', 'Weird combo', 'Fries dipped in milkshake'),
  ('Chill game', 'Rage game', 'Monopoly'),
  ('Normal breakfast', 'Weird breakfast', 'Pizza for breakfast'),
  ('Bad life advice', 'Great life advice', '“Just be yourself”'),
  ('Mild inconvenience', 'Total disaster', 'Losing your keys'),
  ('Lazy weekend', 'Productive weekend', 'Cleaning the whole house'),
  ('Old person thing', 'Young person thing', 'Doing crosswords'),
  ('Useless in a zombie apocalypse', 'Essential in a zombie apocalypse', 'A frying pan'),
  ('Boring superpower', 'Amazing superpower', 'Never getting lost'),
  ('Easy dance', 'Hard dance', 'The Macarena'),
  ('Cheap date snack', 'Fancy date snack', 'Strawberries and champagne'),
  ('Never regift', 'Perfect to regift', 'Scented candles'),
  ('Better hot', 'Better cold', 'Pizza'),
  ('Nobody likes it', 'Everybody likes it', 'Coriander'),
  ('Pointless on holiday', 'Essential on holiday', 'A travel pillow'),
  ('Quick fix', 'Long-term solution', 'Duct tape'),
  ('Polite on a train', 'Rude on a train', 'Eating a tuna sandwich'),
  ('Not worth the hype', 'Worth the hype', 'Hot yoga'),
  ('Ancient history', 'Feels like yesterday', 'The year 2010'),
  ('Plain', 'Over the top', 'A gender reveal party'),
  ('Bad to binge', 'Perfect to binge', 'A cooking show')
on conflict do nothing;

-- Scales players wrote that aren't in the deck, waiting for the admin.
create table if not exists public.ti_scale_submissions (
  id bigint generated always as identity primary key,
  left_label text not null,
  right_label text not null,
  clue text not null,
  by_name text,
  uses int not null default 1,
  status text not null default 'pending' check (status in ('pending', 'dismissed')),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now()
);
create unique index if not exists ti_submissions_unique on public.ti_scale_submissions (lower(left_label), lower(right_label), lower(clue));
alter table public.ti_scale_submissions enable row level security;

-- ---------------------------------------------------------------- game log
-- Kept after rooms are deleted, for the admin's history.
create table if not exists public.ti_game_log (
  id bigint generated always as identity primary key,
  room text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  rounds_played int not null default 0,
  players int not null default 0
);
create index if not exists ti_game_log_room on public.ti_game_log (room, id desc);
create table if not exists public.ti_round_log (
  at timestamptz not null default now(),
  room text not null,
  left_label text not null,
  right_label text not null,
  clue text
);
alter table public.ti_game_log enable row level security;
alter table public.ti_round_log enable row level security;

create or replace function public.ti_log_room()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.ti_game_log (room) values (new.code);
  elsif new.status = 'finished' and old.status <> 'finished' then
    update public.ti_game_log set finished_at = now()
      where id = (select max(id) from public.ti_game_log where room = new.code);
  elsif old.status = 'finished' and new.status = 'playing' then
    insert into public.ti_game_log (room, players)
      values (new.code, (select count(*) from public.ti_players where room = new.code and left_at is null));
  end if;
  return null;
end
$$;
drop trigger if exists ti_log_room on public.ti_rooms;
create trigger ti_log_room after insert or update of status on public.ti_rooms
  for each row execute function public.ti_log_room();

create or replace function public.ti_log_players()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  update public.ti_game_log
    set players = greatest(players, (select count(*) from public.ti_players where room = new.room and left_at is null))
    where id = (select max(id) from public.ti_game_log where room = new.room);
  return null;
end
$$;
drop trigger if exists ti_log_players on public.ti_players;
create trigger ti_log_players after insert or update of left_at on public.ti_players
  for each row execute function public.ti_log_players();

-- When a round is sent: log the scale, and keep it for review if it's new.
-- When it's revealed: count it as played.
create or replace function public.ti_log_round()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if old.phase = 'clue' and new.phase = 'guessing' then
    insert into public.ti_round_log (room, left_label, right_label, clue) values (new.room, new.left_label, new.right_label, new.clue);
    if new.clue is not null and not exists (
      select 1 from public.ti_deck d
      where lower(d.left_label) = lower(new.left_label) and lower(d.right_label) = lower(new.right_label) and lower(d.clue) = lower(new.clue)
    ) then
      insert into public.ti_scale_submissions (left_label, right_label, clue, by_name)
        values (new.left_label, new.right_label, new.clue,
                (select p.name from public.ti_players p where p.room = new.room and p.user_id = new.psychic))
        on conflict (lower(left_label), lower(right_label), lower(clue))
        do update set uses = public.ti_scale_submissions.uses + 1, last_at = now();
    end if;
  elsif new.phase = 'reveal' and old.phase <> 'reveal' then
    update public.ti_game_log set rounds_played = rounds_played + 1
      where id = (select max(id) from public.ti_game_log where room = new.room);
  end if;
  return null;
end
$$;
drop trigger if exists ti_log_round on public.ti_rounds;
create trigger ti_log_round after update of phase on public.ti_rounds
  for each row execute function public.ti_log_round();

-- Existing rooms get a log row so they show up.
insert into public.ti_game_log (room, started_at, players)
  select r.code, r.created_at, (select count(*) from public.ti_players p where p.room = r.code and p.left_at is null)
  from public.ti_rooms r where not exists (select 1 from public.ti_game_log g where g.room = r.code);

-- ---------------------------------------------------------------- players
-- The 🎲 suggestions (everything not hidden).
create or replace function public.ti_suggestions()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('left', left_label, 'right', right_label, 'clue', clue) order by id), '[]'::jsonb)
  from public.ti_deck where not hidden
$$;

-- ---------------------------------------------------------------- admin
create or replace function public.ti_admin_stats()
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  return jsonb_build_object(
    'games', (select count(*) from public.ti_game_log),
    'finished', (select count(*) from public.ti_game_log where finished_at is not null),
    'rounds', (select coalesce(sum(rounds_played), 0) from public.ti_game_log),
    'games_week', (select count(*) from public.ti_game_log where started_at > now() - interval '7 days'),
    'avg_players', (select round(avg(players), 1) from public.ti_game_log where players > 0),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object('day', d::date, 'games', (
        select count(*) from public.ti_game_log g where g.started_at >= d and g.started_at < d + interval '1 day')) order by d)
      from generate_series(date_trunc('day', now()) - interval '13 days', date_trunc('day', now()), interval '1 day') d), '[]'::jsonb),
    'top_scales', coalesce((
      select jsonb_agg(x order by x->>'uses' desc) from (
        select jsonb_build_object('left', min(left_label), 'right', min(right_label), 'uses', count(*)) x
        from public.ti_round_log group by lower(left_label), lower(right_label)
        order by count(*) desc limit 10) t), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('room', room, 'started_at', started_at, 'finished_at', finished_at,
                                          'rounds', rounds_played, 'players', players) order by id desc)
      from (select * from public.ti_game_log order by id desc limit 15) g), '[]'::jsonb)
  );
end
$$;

create or replace function public.ti_admin_deck()
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  return jsonb_build_object(
    'deck', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'left', left_label, 'right', right_label, 'clue', clue,
                                                          'hidden', hidden, 'source', source) order by id desc)
                      from public.ti_deck), '[]'::jsonb),
    'pending', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'left', s.left_label, 'right', s.right_label, 'clue', s.clue,
                                                             'by', s.by_name, 'uses', s.uses, 'last_at', s.last_at,
                                                             'new_scale', not exists (select 1 from public.ti_deck d
                                                               where lower(d.left_label) = lower(s.left_label) and lower(d.right_label) = lower(s.right_label)))
                                          order by s.last_at desc)
                         from public.ti_scale_submissions s where s.status = 'pending'), '[]'::jsonb)
  );
end
$$;

-- Add (p_id null) or edit a deck entry.
create or replace function public.ti_admin_deck_save(p_id bigint, p_left text, p_right text, p_clue text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_left text := left(regexp_replace(trim(coalesce(p_left, '')), '\s+', ' ', 'g'), 40);
  v_right text := left(regexp_replace(trim(coalesce(p_right, '')), '\s+', ' ', 'g'), 40);
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  perform public.ti_require_admin();
  if v_left = '' or v_right = '' or v_clue = '' then
    raise exception 'Fill in both ends and the clue';
  end if;
  if exists (select 1 from public.ti_deck where lower(left_label) = lower(v_left) and lower(right_label) = lower(v_right)
             and lower(clue) = lower(v_clue) and id is distinct from p_id) then
    raise exception 'That scale and clue are already in the deck';
  end if;
  if p_id is null then
    insert into public.ti_deck (left_label, right_label, clue, source) values (v_left, v_right, v_clue, 'admin');
  else
    update public.ti_deck set left_label = v_left, right_label = v_right, clue = v_clue where id = p_id;
  end if;
end
$$;

create or replace function public.ti_admin_deck_hide(p_id bigint, p_hidden boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  update public.ti_deck set hidden = p_hidden where id = p_id;
end
$$;

create or replace function public.ti_admin_deck_delete(p_id bigint)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  delete from public.ti_deck where id = p_id;
end
$$;

-- Accept a player's scale into the deck (optionally edited first).
create or replace function public.ti_admin_submission_accept(p_id bigint, p_left text, p_right text, p_clue text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_left text := left(regexp_replace(trim(coalesce(p_left, '')), '\s+', ' ', 'g'), 40);
  v_right text := left(regexp_replace(trim(coalesce(p_right, '')), '\s+', ' ', 'g'), 40);
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  perform public.ti_require_admin();
  if v_left = '' or v_right = '' or v_clue = '' then
    raise exception 'Fill in both ends and the clue';
  end if;
  insert into public.ti_deck (left_label, right_label, clue, source) values (v_left, v_right, v_clue, 'player')
    on conflict do nothing;
  delete from public.ti_scale_submissions where id = p_id;
end
$$;

-- Not for the deck: stays out of the review list even if it's used again.
create or replace function public.ti_admin_submission_dismiss(p_id bigint)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  update public.ti_scale_submissions set status = 'dismissed' where id = p_id;
end
$$;

-- Watch any room as a silent spectator. The secret spot and locked guesses are
-- included; the page keeps them covered until the admin chooses to look.
create or replace function public.ti_admin_room_state(p_code text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
begin
  perform public.ti_require_admin();
  select * into r from public.ti_rooms where code = upper(trim(coalesce(p_code, '')));
  if r.code is null then
    return jsonb_build_object('missing', true);
  end if;
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  return jsonb_build_object(
    'code', r.code,
    'host', r.host,
    'status', r.status,
    'round', r.round,
    'rounds_total', r.rounds_total,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.user_id, 'name', p.name, 'seat', p.seat, 'score', p.score,
                                          'online', p.last_seen > now() - interval '45 seconds') order by p.seat)
      from public.ti_active_players(r.code) p), '[]'::jsonb),
    'current', case when rd.room is null then null else jsonb_build_object(
      'n', rd.n, 'psychic', rd.psychic, 'left', rd.left_label, 'right', rd.right_label, 'clue', rd.clue, 'phase', rd.phase,
      'precision', coalesce(rd.precision, r.precision),
      'target', (select target from public.ti_round_secrets s where s.room = r.code and s.n = rd.n),
      'guesses', coalesce((select jsonb_agg(jsonb_build_object('user_id', g.user_id, 'value', g.value, 'points', g.points))
                           from public.ti_guesses g where g.room = r.code and g.n = rd.n), '[]'::jsonb)
    ) end
  );
end
$$;

do $$
declare
  f text;
begin
  foreach f in array array['ti_suggestions()', 'ti_admin_stats()', 'ti_admin_deck()', 'ti_admin_deck_save(bigint, text, text, text)',
    'ti_admin_deck_hide(bigint, boolean)', 'ti_admin_deck_delete(bigint)', 'ti_admin_submission_accept(bigint, text, text, text)',
    'ti_admin_submission_dismiss(bigint)', 'ti_admin_room_state(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['ti_log_room()', 'ti_log_players()', 'ti_log_round()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
end
$$;
