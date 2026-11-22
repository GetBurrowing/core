# Studio draft discard and rollback

Discard hides a draft while retaining the post, media references, agent request
and render-destination reservations, and audit events. A human with the existing
rejecter authority may discard, including for an archived account. Restore
requires the stricter approver authority and a live account, in the same profile;
it also checks destination uniqueness. A discarded draft continues to block
profile deletion and clip undo. Discard does not delete files, approve a post or
publish it.

People who currently pass the rejecter rule can view discarded drafts and
their history in that profile. Recovery explains when restoration is
unavailable. A discard is not immediately reversible while its account is
archived or no one is eligible under the account's approver rule; it remains
retained until the account and authority conditions permit restoration.

The schema migration is listed as irreversible for the updater. The managed
updater's crossing procedure and rollback barrier apply, but do not protect a
manual image or binary swap. An older application ignores the marker and can
show discarded drafts as active. Attempts to advance such a draft may violate
the new database check and raise an error. Do not run an older binary against a
database containing discarded drafts; keep the compatible application in place
or arrange a separately reviewed recovery before a manual downgrade.

Do not delete markers or audit events to force a rollback. The migration's
down path refuses while any discarded marker or discard/restore event exists,
including event history after restoration.
