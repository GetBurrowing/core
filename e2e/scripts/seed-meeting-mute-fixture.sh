#!/usr/bin/env bash
# Seed the fixture `meeting_mute_glyph.spec.ts` reads
# (task 01a07486-7985-7001-87ce-277681791f52, FE-19 stage 3).
#
# WHY SQL AND NOT `mix run`. Same reason as
# `seed-meeting-layout-fixture.sh`: the serving BEAM has no Erlang
# distribution, so nothing outside it can call in, and a second `mix run`
# BEAM never shares that node's ETS or PubSub. The database is the only
# surface both processes see.
#
# WHY TWO HUMANS AND NOT ONE. `meeting_live.html.heex` folds the roster's
# off-sets through `MeetingLive.roster_off_set/3`, which REPLACES the
# viewer's own entry with the viewer's local `@mic_enabled` /
# `@camera_enabled` booleans. That is deliberate (LiveKit's
# `remoteParticipants` never contains the viewer, so without the fold the one
# row the viewer looks at most is the one that lies), and it means a
# `media_states` push naming the logged-in user is discarded. The spec logs
# in as the first human and mutes the second.
#
# WHY THE ROOM AND NOT THE MEETING carries the participants: `meeting_rooms`
# is what `meeting_participants` hangs off, and `get_active_room/1` filters
# on `status = 'active'`. Seeding against the meeting id instead yields an
# empty roster, which looks exactly like the rail being broken.
#
# Usage:
#   e2e/scripts/seed-meeting-mute-fixture.sh
#   PLATFORM_DEV_DATABASE=platform_dev_myworktree e2e/scripts/seed-meeting-mute-fixture.sh
#
# Env:
#   PLATFORM_DEV_DATABASE   database to seed (default: platform_dev, matching
#                           apps/platform/config/dev.exs)
#   PSQL                    psql invocation (default: `psql`)
#
# Precondition: log in once at /dev/login?as=alice so the `general` chat
# space and the Fabrikam org exist. This script does not create them.
set -euo pipefail

DB="${PLATFORM_DEV_DATABASE:-platform_dev}"
PSQL="${PSQL:-psql}"

"$PSQL" -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  v_space uuid;
  v_org   uuid;
  v_room  uuid;
  v_host  uuid;
  v_alice uuid;
  v_bob   uuid;
BEGIN
  SELECT id INTO v_space FROM chat_spaces WHERE slug = 'general' LIMIT 1;
  IF v_space IS NULL THEN
    RAISE EXCEPTION 'no ''general'' chat space — log in once at /dev/login?as=alice first';
  END IF;

  SELECT id INTO v_org  FROM orgs ORDER BY inserted_at LIMIT 1;
  SELECT id INTO v_host FROM chat_participants
    WHERE space_id = v_space AND participant_type = 'user' LIMIT 1;
  SELECT id INTO v_alice FROM users WHERE email = 'alice@localhost' LIMIT 1;
  IF v_alice IS NULL THEN
    RAISE EXCEPTION 'no alice@localhost user — log in once at /dev/login?as=alice first';
  END IF;

  -- The muted SUBJECT. Has to be somebody other than whoever the spec logs
  -- in as; see the header.
  SELECT id INTO v_bob FROM users WHERE email = 'bob@localhost' LIMIT 1;
  IF v_bob IS NULL THEN
    v_bob := gen_random_uuid();
    INSERT INTO users (id, email, name, oidc_sub, inserted_at, updated_at)
    VALUES (v_bob, 'bob@localhost', 'Dev Bob', 'dev-bob', now(), now());
  END IF;

  SELECT id INTO v_room FROM meeting_rooms WHERE space_id = v_space LIMIT 1;
  IF v_room IS NULL THEN
    v_room := gen_random_uuid();
    INSERT INTO meeting_rooms (id, space_id, livekit_room_name, status, config, inserted_at, updated_at)
    VALUES (v_room, v_space, 'fe19-mute-room', 'active', '{}', now(), now());
  ELSE
    UPDATE meeting_rooms SET status = 'active', updated_at = now() WHERE id = v_room;
  END IF;

  DELETE FROM meeting_participants WHERE room_id = v_room;

  -- `metadata->>'identity'` is what `MeetingLive.gallery_identity/1` reads
  -- first, and it is the string the rail's `data-participant` attribute
  -- carries. The spec harvests those attributes and pushes them straight
  -- back as the `media_states` payload, so these two have to agree.
  INSERT INTO meeting_participants (id, room_id, user_id, display_name, joined_at, metadata)
  VALUES
    (gen_random_uuid(), v_room, v_alice, 'Dev Alice', now(),
     jsonb_build_object('identity', 'user:' || v_alice)),
    (gen_random_uuid(), v_room, v_bob, 'Dev Bob', now(),
     jsonb_build_object('identity', 'user:' || v_bob));

  INSERT INTO projects (id, name, slug, org_id, inserted_at, updated_at)
  VALUES ('01a07486-0000-7001-0000-000000000001', 'Mute Glyph Gate', 'mute-glyph-gate', v_org, now(), now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO meetings (id, project_id, chat_space_id, slug, name, status,
                        livekit_room_name, host_participant_id, started_at, inserted_at, updated_at)
  VALUES ('01a07486-0000-7001-0000-000000000002', '01a07486-0000-7001-0000-000000000001', v_space,
          'mute-glyph-gate', 'Mute Glyph Gate', 'active', 'fe19-mute-room', v_host, now(), now(), now())
  ON CONFLICT (id) DO UPDATE
    SET status = 'active', started_at = now(), updated_at = now();

  RAISE NOTICE 'seed: ok — meeting slug ''mute-glyph-gate'', room %, 2 human participant(s)', v_room;
END $$;
SQL
