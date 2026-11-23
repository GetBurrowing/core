# Social quality-review migration

Migration `20261123120000_add_social_quality_review.exs` introduces two-stage
review for legacy Social posts. It adds the profile's quality reviewer list
(non-null, default empty), three nullable pass fields on the post, a user FK
for the passer, and the `quality_review` post status. It preserves every
existing status, including Studio's `planned`, and leaves Studio's boundary
CHECK and post history actions unchanged.

The migration does not enroll reviewers, move posts, backfill passes, alter
approval lists, or schedule or publish anything. Existing profiles keep an
empty reviewer list and existing posts have no pass. Configuring a brand's
first quality reviewer is a separate operator action; existing posts awaiting
approval then require a valid pass under the new application rules, without
being moved automatically.

Before crossing this release, take the required database dumps of all three
installations and verify that each dump parses end to end. Ship the compatible
application and migration together through the normal release mechanism.
Keep old application instances stopped once the migration is crossed: they
cannot handle the new status and do not enforce the quality-pass requirement.

A current quality reviewer or the account's existing final approver can send a
quality-stage post back to draft with a required note. This does not grant edit
or Pass authority to an approver, and works if the reviewer list becomes empty.

An older failed post without a valid pass on a gated brand can remain blocked
from starting a new job. A missing external job ID or zero recorded attempts
does not prove remote absence. This slice provides no safe automatic recovery
for an uncertain remote outcome; it requires separate investigation. Do not
recreate the post or temporarily remove reviewers as a workaround. The retry
of an identified existing vendor job retains its existing compatibility path.

The version is registered in `deployment/release/irreversible-migrations.txt`.
The host updater holds a release containing this migration for an explicit
Update now and a dump, and refuses its automatic rollback across the barrier.
This is the updater's protection, not a database-wide lock on deployments:
manual image swaps, other deployment mechanisms, and interrupted crossing
runs are not protected by it. Do not infer those paths are safe from the
registry entry.

`down/0` always refuses, even when the reviewer list and pass fields are empty.
Fix forward. Disaster recovery requires stopping writers and restoring a
pre-crossing database dump with its matching older application as one recovery
operation; a database restore can lose writes made after that dump. Do not
drop the pass columns, rewrite statuses, or simply run an older image against
the migrated database as a rollback shortcut.

This document and the migration definition do not execute any installation
change. Local migration tests use a disposable test database only.
