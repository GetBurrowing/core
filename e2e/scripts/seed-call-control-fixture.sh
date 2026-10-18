#!/usr/bin/env bash
# Seed the fixture `call_control_label_swing.spec.ts` measures against
# (task 01a0773e-cea9-7001-98f5-be6c37607e91 / FE-20 stage 1).
#
# WHY A SECOND SEED SCRIPT. `seed-meeting-layout-fixture.sh` is the sibling
# gate's fixture and it talks to test-host over ssh (`ssh deploy@test-host.local podman
# exec dev-postgres psql ...`). This probe runs against a LOCAL dev server, so
# it needs a LOCAL psql. Sharing one script would have meant a transport flag
# threaded through every statement; the two fixtures also want different rows
# (that one wants agent participants and candidate cards, this one wants a live
# meeting and nothing else). Keeping them apart means neither can break the
# other by growing.
#
# WHAT `/meetings/:slug` NEEDS BEFORE IT WILL RENDER A CONTROL ROW:
#
#   1. A `chat_spaces` row with slug 'general'. `/dev/login?as=<who>` creates
#      it and adds the user, so this script requires a login to have happened
#      and says so rather than inventing a space.
#   2. A `meeting_rooms` row for that space. `Meetings.ensure_room/1` writes it
#      on the first join. Created here directly so a cold database does not
#      need a manual click in /chat first.
#   3. A `meetings` row with status 'live'. Without it `/meetings/<slug>` 404s
#      and the run reads as "the controls are missing".
#
# WHY IT DELETES `meeting_participants`. The joined state persists in that
# table across server restarts, so a second run would find the surface already
# joined and would never exercise the join prelude. An unexercised prelude is
# how a probe stops testing the path it claims to test. Clearing the rows makes
# every run start COLD, which is the state stage 3 will re-run from.
#
# Usage: seed-call-control-fixture.sh --db platform_01a0773e_fe20 [--psql-user postgres]
set -euo pipefail

DB=""; PGUSER_ARG="postgres"; SPACE_SLUG="general"; MEETING_SLUG="label-swing"
while [ $# -gt 0 ]; do
  case "$1" in
    --db)         DB="${2:-}";         shift 2 ;;
    --psql-user)  PGUSER_ARG="${2:-}"; shift 2 ;;
    --space-slug) SPACE_SLUG="${2:-}"; shift 2 ;;
    --meeting-slug) MEETING_SLUG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,32p' "$0"; exit 2 ;;
    *) echo "seed-call-control-fixture: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$DB" ] || { echo "seed-call-control-fixture: --db is required" >&2; exit 2; }

psql_q() { psql -U "$PGUSER_ARG" -d "$DB" -v ON_ERROR_STOP=1 -tA; }

space_id="$(echo "select id from chat_spaces where slug='$SPACE_SLUG' limit 1;" | psql_q)"
if [ -z "$space_id" ]; then
  echo "seed: no '$SPACE_SLUG' chat space in $DB — open /dev/login?as=robin once first." >&2
  echo "      That route creates the space and adds the user; this script will not invent one," >&2
  echo "      because a fabricated space would render a control row nobody can reach in the app." >&2
  exit 2
fi

org_id="$(echo "select id from orgs order by inserted_at limit 1;" | psql_q)"
host_id="$(echo "select id from chat_participants where space_id='$space_id' and participant_type='user' limit 1;" | psql_q)"
if [ -z "$org_id" ] || [ -z "$host_id" ]; then
  echo "seed: no org or no user participant in $DB — log in at /dev/login?as=robin first." >&2
  exit 2
fi

psql_q <<SQL
-- The room is what a join hangs off. ensure_room/1 writes it on first join;
-- creating it here means a cold database needs no manual click in /chat.
insert into meeting_rooms (id, space_id, livekit_room_name, status, config, inserted_at, updated_at)
select gen_random_uuid(), '$space_id', 'space-$space_id', 'active', '{}', now(), now()
where not exists (select 1 from meeting_rooms where space_id = '$space_id');

update meeting_rooms set status = 'active' where space_id = '$space_id';

insert into projects (id, name, slug, org_id, inserted_at, updated_at)
values ('01a0773e-0000-7001-0000-000000000001','Label Swing Gate','label-swing-gate','$org_id',now(),now())
on conflict (slug) do nothing;

-- status must be 'live': get_live_meeting_for_space/1 filters on it, and a
-- 'scheduled' row leaves the surface with no call shell at all.
insert into meetings (id, project_id, chat_space_id, slug, name, status, livekit_room_name,
                      host_participant_id, started_at, inserted_at, updated_at)
select '01a0773e-0000-7001-0000-000000000002','01a0773e-0000-7001-0000-000000000001',
       '$space_id','$MEETING_SLUG','Label Swing','live', mr.livekit_room_name,
       '$host_id', now(), now(), now()
from meeting_rooms mr where mr.space_id = '$space_id' limit 1
on conflict (project_id, slug) do update set status = 'live', ended_at = null, updated_at = now();

-- COLD START. See the header: a surviving participant row makes the next run
-- skip the join prelude, and a prelude that never runs is a prelude that is no
-- longer being tested.
delete from meeting_participants
where room_id in (select id from meeting_rooms where space_id = '$space_id');
SQL

rooms="$(echo "select count(*) from meeting_rooms where space_id='$space_id';" | psql_q)"
parts="$(echo "select count(*) from meeting_participants mp join meeting_rooms mr on mr.id = mp.room_id where mr.space_id='$space_id';" | psql_q)"
echo "seed: ok — db=$DB space=$SPACE_SLUG($space_id) meeting=$MEETING_SLUG rooms=$rooms participants=$parts (0 = cold, join prelude will run)"
