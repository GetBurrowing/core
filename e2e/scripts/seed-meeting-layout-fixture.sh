#!/usr/bin/env bash
# Seed the fixture `meeting_layout_geometry.spec.ts` measures against.
#
# WHY SQL AND NOT `mix run`. There is no Erlang distribution on the dev
# container's serving BEAM (it is PID 1, started as `mix phx.server` with no
# `-sname`), so nothing outside the node can call into it. A `mix run` in the
# same container starts a SECOND, separate BEAM whose ETS and PubSub the
# serving process never sees — and under `MIX_ENV=test` it also escapes the
# Ecto sandbox and leaves rows that cause phantom failures in unrelated
# suites. The database is the only shared surface, so the fixture is written
# there.
#
# WHAT THIS CANNOT SEED, AND THE SPEC SAYS SO ON EVERY RUN. The three
# non-idle agent activity states have in-memory-only producers —
# `Platform.Meetings.IntentQueue` for `:computing`, a transient PubSub
# broadcast for `:typing`, a queue terminal transition for `:failed`. None of
# them has a row anywhere. Every seeded agent therefore renders `:idle`, and
# the spec PRINTS which states a run exercised rather than letting the
# glyph-overlap branch pass vacuously.
#
# Usage: seed-meeting-layout-fixture.sh <task-slug>
set -euo pipefail

SLUG="${1:?usage: seed-meeting-layout-fixture.sh <task-slug>}"
DB="platform_dev_$(echo "$SLUG" | tr '-' '_')"
# SQL GOES OVER STDIN, NEVER AS `psql -c "<sql>"` THROUGH ssh. `ssh` joins
# its argv with spaces and re-parses the result in the remote shell, so the
# quotes around a `-c` argument are gone by the time psql sees it and the
# statement arrives as a fistful of "extra command-line argument ignored"
# warnings plus an empty result — which then reads as "the row does not
# exist" and the script exits claiming the fixture is unseeded.
psql_q() {
  ssh deploy@test-host.local "podman exec -i dev-postgres psql -U postgres -d '$DB' -v ON_ERROR_STOP=1 -tA"
}

space_id=$(echo "select id from chat_spaces where slug='general' limit 1;" | psql_q)
if [ -z "$space_id" ]; then
  echo "seed: no 'general' chat space in $DB — log in once at /dev/login?as=alice first" >&2
  exit 2
fi

org_id=$(echo "select id from orgs order by inserted_at limit 1;" | psql_q)
host_id=$(echo "select id from chat_participants where space_id='$space_id' and participant_type='user' limit 1;" | psql_q)

# The room is what `meeting_participants` hangs off — NOT the meeting.
# `Platform.Meetings.ensure_room/1` returns a Room, and seeding against a
# meeting id instead produces a rail where every row renders `idle` for a rig
# reason that looks exactly like the feature being broken.
room_id=$(echo "select id from meeting_rooms where space_id='$space_id' limit 1;" | psql_q)
if [ -z "$room_id" ]; then
  echo "seed: no meeting_room for the general space — click Join in /chat/general once first" >&2
  exit 2
fi

psql_q <<SQL
insert into agents (id, slug, name, status, model_config, tools_config, voice_config, kind, inserted_at, updated_at)
select gen_random_uuid(), s, initcap(s), 'active', '{}', '{}', '{}', 'native', now(), now()
from unnest(array['geo-alpha','geo-bravo','geo-charlie','geo-delta']) s
where not exists (select 1 from agents where slug = s);

insert into meeting_participants (id, room_id, agent_id, display_name, joined_at, metadata)
select gen_random_uuid(), '$room_id', a.id, a.name, now(), '{}'
from agents a
where a.slug like 'geo-%'
  and not exists (
    select 1 from meeting_participants mp
    where mp.room_id = '$room_id' and mp.agent_id = a.id and mp.left_at is null
  );

insert into projects (id, name, slug, org_id, inserted_at, updated_at)
values ('01a06520-0000-7001-0000-000000000001','Geometry Gate','geometry-gate','$org_id',now(),now())
on conflict (slug) do nothing;

insert into meetings (id, project_id, chat_space_id, slug, name, status, livekit_room_name,
                      host_participant_id, started_at, inserted_at, updated_at)
values ('01a06520-0000-7001-0000-000000000002','01a06520-0000-7001-0000-000000000001','$space_id',
        'geometry-gate','Geometry Gate','active','geometry-gate-room','$host_id',now(),now(),now())
on conflict (project_id, slug) do nothing;

-- CANDIDATE CARDS, for the reading-order assertion. Written straight to
-- meeting_candidates — the table Candidates.list_for_meeting/1 reads —
-- for the same reason the rest of this fixture is SQL: the serving BEAM has
-- no distribution, and mix run under MIX_ENV=test escapes the Ecto sandbox
-- and leaves rows that break unrelated suites. The documented HTTP route
-- (POST /api/meetings/segments) additionally runs the LLM classifier, so
-- what a card ends up saying is not deterministic; these rows are.
--
-- acts_at is an HOUR OUT on the armed card. Candidates.claim_due/2 polls
-- every ~400ms and would close a card with a past acts_at to :done
-- before the browser could read it, which reads exactly like the card
-- failing to render.
insert into meeting_candidates
  (id, meeting_id, org_id, state, outcome_kind, evidence_quote, classified_intent,
   speaker, assigned_agent_slug, target_role, transcript_chunk_ids, acts_at,
   heard_at, last_utterance_at, threading_events, inserted_at, updated_at)
values
  ('01a06520-0000-7001-0000-00000000000a','01a06520-0000-7001-0000-000000000002','$org_id',
   'shaping','task','we should rotate the staging secrets','action_item',
   'Sam Moreno','geo-alpha',null,ARRAY[gen_random_uuid()],null,
   now(),now()-interval '2 minutes','[]',now(),now()),
  ('01a06520-0000-7001-0000-00000000000b','01a06520-0000-7001-0000-000000000002','$org_id',
   'shaping','task','and somebody should rewrite the pricing copy','action_item',
   null,null,'null',ARRAY[gen_random_uuid()],null,
   now(),now()-interval '3 minutes','[]',now(),now()),
  ('01a06520-0000-7001-0000-00000000000c','01a06520-0000-7001-0000-000000000002','$org_id',
   'heard','task','let us pin the deploy target before Friday',null,
   'Sam Moreno',null,null,ARRAY[gen_random_uuid()],null,
   now(),now()-interval '1 minute','[]',now(),now()),
  ('01a06520-0000-7001-0000-00000000000d','01a06520-0000-7001-0000-000000000002','$org_id',
   'shaping','task','open a ticket for the flaky pins test','action_item',
   'Sam Moreno','geo-bravo',null,ARRAY[gen_random_uuid()],now()+interval '1 hour',
   now(),now()-interval '30 seconds','[]',now(),now())
on conflict (id) do update set
  acts_at = excluded.acts_at,
  state = excluded.state,
  closed_at = null,
  closed_reason = null,
  updated_at = now();
SQL

echo "seed: ok — meeting slug 'geometry-gate', room $room_id, $(echo "select count(*) from meeting_participants where room_id='$room_id' and agent_id is not null and left_at is null;" | psql_q) agent participant(s)"
