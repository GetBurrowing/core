# ADR 0058: RBAC v2 — Roles, Scopes, and Agent Capping

**Status:** Proposed
**Date:** 2026-10-14
**Owners:** Rowan, Dalton
**Task:** `01a1386d-a18f-7001-9faa-04316dc0198c` (stack `rbac-roles`, `01a1386d-6d34-7001-9f93-b1428a6b0604`, position 1)
**Design source:** Rowan's settlement on 2026-10-14 in space `019f4882-c8d1-724e-a89e-ecb17d2681c8` (#RBAC System), and prototype canvas `01a1384a-3317-7001-ace5-45c7ef34f08e` ("Access — agent-first prototype").
**Amends (in part, not superseded):** the *authorization* role of capability bundles in `0034-mcp-endpoint-and-capability-bundles.md § Capability bundles` (bundles stop being the thing that grants a tool; see § Agents below, written in stage 2), and the Historian-only page-write rule in `0041-org-memory-v2-wiki-system.md § Historian as sole page writer` (a subtree `memory.write` grant replaces it for agents). Everything else in both ADRs stands.
**Related:** `0042-org-project-topology-and-context-inheritance.md § 3. Context inheritance rules` (the org → project → space tree that grants inherit along), `0040-federated-agent-owner-identity.md § D2. What scope does ownership confer?` (the owner question this ADR answers for authorization), `0057-prototypes-on-suite.md` (prototype grants, one of the bypass surfaces). Runbook for the v1 model: `docs/runbooks/external_users.md`.

This document is written in two passes. This pass records the falsifier check, the measured
premises, the mapping from today's state onto built-in roles, and the bypass-surface table. The
decision sections (permission model, precedence, memory anchoring, agent cap, delegation,
root-admin carve-outs, per-member build map) follow in the second pass and build on the tables
here.

## Context

### Falsifier check (run before writing)

The ticket says: if `docs/decisions/` already holds an accepted ADR for role-based permissions that
supersedes the external-user model, amend that one instead of writing a new one.

Measured on `origin/main` at `b75087dd28ac7a2470d36bfb8c2a001f5e4f7685` (2026-10-14):

```
$ ls docs/decisions | grep -iE 'rbac|role|guest|extern|permission|access|scope'
0014-agent-federation-and-external-runtimes.md
0015-agent-onboarding-and-role-templates.md

$ grep -rliE 'role-based|rbac' docs/decisions
(no output)

$ git log --remotes --diff-filter=A --name-only -- 'docs/decisions/0058*' 'docs/decisions/0059*' 'docs/decisions/006*'
(no output)
```

`0014` covers external agent *runtimes* and `0015` covers agent role *templates*. Neither is a
human permission model. The v1 external-user stack (`rbac-external-users`, rollup PR #584) shipped a
runbook, `docs/runbooks/external_users.md`, not an ADR. **No ADR on main, and none on any remote
branch, covers role-based permissions, so this is a new ADR.** The highest number on main is
`0057-prototypes-on-suite.md`, which makes `0058` the next free number.

The branch is cut from `origin/stack/rbac-roles` (`e93f0ea07`), which is an ancestor of the main sha
above. Every `file:line` in this document was read on main `b75087dd2`, not on the stack base.
`apps/platform/lib/platform/orchestration/task_router.ex` is the only cited file that differs
between the two.

### Measured premises

All paths are relative to `apps/platform/`. Every line was read on main `b75087dd2`. These are
readings of the source. Except where stated, nothing here was observed on a running install.

**Today's read scope is external-only.**
- `Platform.Chat.ExternalScope` is at `lib/platform/chat/external_scope.ex:1`. Its struct is
  `defstruct user_id: nil, external?: false` (`:66`), and it is built by `for_user/1` (`:79-83`).
- Every filter in it passes non-external scopes straight through: `scope_spaces/2` (`:112`),
  `scope_by_space_id/2` (`:124`) and `visible_space_id?/2` (`:138`). For an external scope they
  narrow to `member_space_ids/1` (`:96`), which is the user's `chat_participants` rows.
- The admission predicate `authorized_space?/2` (`:162-164`) is participation OR
  `dm_allowlisted?/2` (`:173`).
- So the only per-user read scope in the product today is for external users. An internal user's
  reach is decided elsewhere (see the visibility and mapping rows below).

**Role is two values, and `external` is a separate axis.**
- `@roles ~w(admin member)` is at `lib/platform/tenancy/org_membership.ex:45`. The planner's `:44`
  has drifted by one line. The DB `CHECK (role IN ('admin', 'member'))` is at
  `priv/repo/migrations/20260519143610_create_org_memberships.exs:63`.
- The `external` boolean is at `org_membership.ex:54`. The moduledoc at `org_membership.ex:20-36`
  says the two axes are modelled independently so that "external admin" stays expressible.
- `Tenancy.external_user?/1` (`lib/platform/tenancy.ex:817-821`) is true when ANY membership in ANY
  org has `external == true`. It is by-user, not by-org.

**Org visibility keys off root-org membership, not role.**
- `Tenancy.visibility/1` (`tenancy.ex:549-574`) returns `:root_all` for a member of the root org at
  ANY role (`root_member?/1`, `tenancy.ex:1093`). Otherwise it returns `{:orgs, ids}` from the
  user's memberships, or `:none` when there are none. `Tenancy.scope/3` passes `:root_all` through
  unchanged (`:614`).
- `root_member?/1` and `root_admin?/1` both go through `root_membership_query/2`
  (`tenancy.ex:1106-1116`), which **does not filter on `external`**. An `external: true` row on the
  root org therefore answers `true` to both.
- By contrast, `org_admin?/2` (`tenancy.ex:1168`) goes through `internal_membership_exists?/3`,
  which requires `m.external == false` (`:1193`). So the external flag strips org-admin powers but
  not root-admin or root visibility.
- **Every OIDC-provisioned user holds a root-org membership.** `insert_user_with_membership/1`
  (`lib/platform/accounts.ex:356-366`) calls `Tenancy.apply_derived_role/1` (`tenancy.ex:1737`),
  which upserts a row on the root org at the email-derived role (`member` unless the admin email
  domain matches, `:1622-1632`). External admission goes through `find_or_create_from_oidc/1` first
  (`lib/platform/accounts/external_admission.ex:118`), so an external user normally carries an
  internal root-org `member` row plus an `external: true` row on their tenant org. As a result,
  `visibility/1` says `:root_all` for nearly every real user, including external ones. **What keeps
  external users in, today, is the HTTP plug and `ExternalScope`, not `visibility/1`.** A user with
  sub-org rows and no root-org row exists only outside the OIDC insert path (seeds, tests, or a
  removed root row). This pass did not audit every caller that could delete a root-org row.

**Install-level admin is root admin, not org admin.**
- `Tenancy.root_admin?/1` is at `tenancy.ex:1075`. Its doc says sub-org admins return `false`.
- The `/admin/*` gate is `LiveAuth.on_mount(:ensure_admin)` (`lib/platform_web/live_auth.ex:47`).
  It checks `socket.assigns[:root_admin?]` (`:48`), which `:default` sets from
  `root_admin_safely/1` (`:39-44`). The `:admin` live_session that applies it is at
  `lib/platform_web/router.ex:933-980`, covering `/admin`, recovery, external-logins, users, orgs,
  branding, prototypes, vault, prompts, federation and pipeline.
- **Org admin has its own small set of powers, and none of them is install-level:** mail-account
  management (`lib/platform/mail.ex:61`), prototype publish under the `"admins"` policy
  (`lib/platform/prototypes.ex:208`, OR root admin), and quarantine promotion
  (`lib/platform/tasks.ex:7378-7379`, OR root admin).

**OIDC external marker.**
- `OIDC_EXTERNAL_GROUP` is read at `config/runtime.exs:180` and defaults to `sxi-external`;
  `OIDC_EXTERNAL_CLAIM` (`:181`) names the claim and defaults to `groups`.
- The predicate is `Platform.OIDC.external_claim?/1` (`lib/platform/oidc.ex:59`).
  `claim_groups/1` (`oidc.ex:92`) returns the multi-valued group list that
  `Tenancy.resolve_org_from_groups/1` (`tenancy.ex:923-927`) consumes. So the marker is a single
  group, but the data under it is already a list.

**Org-memory writes: agents are gated, humans are not.**
- The Historian gate is `Platform.Org.Wiki.Routing.gate_write/3` (`lib/platform/org/wiki/routing.ex:294`).
  Its first argument is an agent, and Historian status is a `role_assignments` pin
  (`historian?/1`, `routing.ex:210-214`).
- Its only callers are in `lib/platform/federation/tool_surface.ex` (`:7425`, `:7442`, `:7454`,
  `:7464`, `:12121`). `grep -rn 'gate_write(' lib` finds no other call site.
- Human edits go through `OrgMemoryLive` → `Wiki.upsert_page/3`
  (`lib/platform_web/live/org_memory_live/view.ex:674` for create and `:1129` for save). That path
  has no role check: any authenticated human who gets past `ExternalUserScope` can write.
- Agent-shaped actors are refused in the UI at `view.ex:613-618` (planner's `:608-614` has
  drifted). The only refusal in the domain is product-owned keys, in `Wiki.upsert_page/3`
  (`lib/platform/org/wiki.ex:393-397`, `check_product_owned/2`).
- External users never reach `/org_memory` over HTTP: it is not on the `ExternalUserScope`
  allowlist (`lib/platform_web/plugs/external_user_scope.ex:147`, `external_non_chat_route`).

**Capability bundles are the agent authorization today.**
- `@default_allowed_bundles` is at `lib/platform/agents/agent_runtime.ex:54`, and the per-runtime
  `allowed_bundles` field at `:64`. They are changed through `Federation.update_allowed_bundles/2`
  (`lib/platform/federation.ex:107`).
- The single enforcement point is `Platform.Federation.ToolAuthorization.authorize/2`
  (`lib/platform/federation/tool_authorization.ex:106`). The MCP controller
  (`lib/platform_web/controllers/mcp_controller.ex:90`) and the runtime channel
  (`lib/platform_web/channels/runtime_channel.ex:857`) both route through it.

**Agent ownership exists only on federated runtimes.**
- `agent_runtimes.owner_user_id` is at `agent_runtime.ex:58` and is required by the changeset
  (`:91`).
- The `agents` schema (`lib/platform/agents/agent.ex:72`) has no owner field. It has `runtime_type`
  (default `"built_in"`, `:85`) and a nullable `runtime_id` (`:86`).
- The existing owner-aware check, prototype publish, reads the owner off the runtime the call
  arrived on (`prototypes.ex:18-19`, `:194`), and "An agent whose runtime has no owner is refused"
  (`:178`). So **a built-in agent has no owner today.** Its cap is decided in the second pass.

**Org memory has no stable node identity.**
- `Wiki.rename_page/3` (`wiki.ex:678`) upserts the content under a NEW `file_key` (`:722`), then
  `Repo.delete/1`s the source row (`:731`). The planner's `:721-730` has drifted by one line. A
  page's row id therefore does not survive a rename.
- A subtree root such as `org/page/eng/` is a path prefix, not a row.
- **This is settled, not open.** Stack member 3 (`01a1386d-e528`, plan `01a13aa3-89c2`) anchors
  memory grants in a new `org_memory_nodes` entity plus `org_memory_node_paths`, which records path
  history:
  - page rows are untouched;
  - a node is created lazily when a grant first needs one;
  - a rename moves the node;
  - deleting a page keeps its node;
  - a rename that overwrites an existing page merges the two nodes' grants, and deny still wins.

  The second pass records this in the memory-grants section.

## Today's state mapped onto built-in roles (no behaviour change)

**Role plus `external` is not enough input to the mapping.** The premises above show that today's
access also depends on three more things:
- root-org versus sub-org membership (`visibility/1` → `:root_all`);
- root admin, the install-level bypass that gates `/admin`;
- space participation (`ExternalScope`, the `chat_participants` row).

So the mapping is per actor class, one row each. A real user is the union of the rows for their
memberships: for example, an OIDC user who is an org admin of a tenant also holds the root-org
`member` row. The one exception is that **guest dominates**: `external_user?/1` is by-user, so a
user with an external row anywhere gets the guest restrictions everywhere, which is what the HTTP
plug enforces today.

The built-in roles are **admin**, **member** and **guest**, stored as data. **Root admin is not a
role.** It is an install-level attribute, an audited bypass, and it is never granted by holding the
built-in `admin` role in any org. The invariant for every row: the mapped permission set grants
exactly what the "today" column grants, no more and no less. That includes today's gaps, which are
closed later by deliberate changes, never by the mapping.

| # | Actor class | Today's code path | Mapped built-in role and permission set |
|---|---|---|---|
| 1 | **Root-org admin** (root admin) | `root_admin?/1` true (`tenancy.ex:1075`). `/admin/*` mounts (`live_auth.ex:47`, `router.ex:933-980`). `visibility/1` gives `:root_all`. Org-reach bypasses: file blobs (`file_blob_controller.ex:207`), canvas `:org_reader` (`canvas_access.ex:488`), quarantine promotion (`tasks.ex:7379`), prototype admin policy (`prototypes.ex:208`). | `admin` on the root org, scope `:all` across orgs, **plus** the separate root-admin bypass. Every install-level permission comes from the bypass, never from the `admin` role. |
| 2 | **Root-org member** (`role: member`, internal) | `visibility/1` gives `:root_all`, so it lists every org's projects (`Tasks.list_projects_for_user/2`, `tasks.ex:331-345`). No `/admin`. Org memory is editable (`view.ex:674`, `:1129`). Chat goes through `ExternalScope` pass-through, with implicit join of `channel`/`system`/`execution` spaces (`chat_live.ex:4334`, `:4346-4351`). File blobs need `member_of?` the project's org (`file_blob_controller.ex:217`), **not** `:root_all`. | `member` on the root org, with org-and-project read at `:all` (reproducing `:root_all`) and `memory.write` at `:all` (reproducing today's ungated edit). `files.read` stays scoped to the orgs the user is a member of, to reproduce the blob controller's narrower rule. |
| 3 | **Sub-org admin** (internal, with no root-org row) | `visibility/1` gives `{:orgs, ids}`. `org_admin?/2` is true for that org (`tenancy.ex:1168`), so it can manage mail accounts (`mail.ex:61`), publish prototypes under the `"admins"` policy (`prototypes.ex:208`) and promote from quarantine (`tasks.ex:7379`). **No `/admin`**: `root_admin?/1` is false. | `admin` scoped to that org. **The built-in `admin` carries no install-level permission**: it has no `/admin` route and no branding, OIDC, prototype-settings or experiments control. On an OIDC install this actor also holds row 2, so their effective set is row 2 ∪ row 3. |
| 4 | **Sub-org member** (internal, with no root-org row) | `visibility/1` gives `{:orgs, ids}`, so projects are fenced to those orgs (`tasks.ex:337-340`). **The Tasks board is not viewer-scoped**: `BoardHooks` calls `Tasks.list_all_tasks/1` with no viewer (`lib/platform_web/live/tasks/board_hooks.ex:207`), so this actor sees every org's tasks on the board. Org memory is editable. | `member` scoped to those orgs. To keep behaviour unchanged, the board's task read reproduces today's unscoped list. Narrowing it is a later, deliberate change recorded as such. |
| 5 | **`external: true` member** | `external_user?/1` true (`tenancy.ex:817`). HTTP is allowlisted to `/`, `/chat` and `/chat/:slug`, plus the meet-host routes; everything else is denied (`external_user_scope.ex:54-63`, `:76-147`). Chat lists and reads are narrowed to participant spaces (`external_scope.ex:96`, `:108`, `:120`, `:133`). DMs are admitted through the per-org allowlist (`external_scope.ex:173`). Canvases need participation only, with no org reach (`canvas_access.ex:343`). Attachments need space membership, and nil-space rows are refused (`chat.ex:4976`). Org admin is off (`tenancy.ex:1193`). | **`guest`** in that org, plus a `chat.read` **and `chat.write`** grant on each `chat_participants` space. Write is included because today an external user posts, uploads and downloads in their spaces (rbac-v1 resolved questions 3 and 4); the planner's `chat.read`-only reading would remove that. The per-org DM allowlist is preserved as is. Guest dominates this user's internal root-org row (see above). |
| 6 | **External admin** (`role: admin`, `external: true`) | On a tenant org, `org_admin?/2` is false (`:1193`), so the admin role grants nothing beyond row 5. On the **root** org, `root_admin?/1` returns **true** (`tenancy.ex:1106-1116` ignores `external`). The only thing holding this user off `/admin` and the other app routes is the `ExternalUserScope` plug, not `:ensure_admin`. | **`guest`**, exactly as row 5. The `admin` role on an external row maps to no permission, and **root-admin bypass is never derived for a user with any external row**, so the plug-only defence becomes a modelled rule. This row is the one place where the stored role and the mapped role differ, and it does so on purpose. |
| 7 | **Agent** | Tools: `allowed_bundles` through `ToolAuthorization.authorize/2` (`tool_authorization.ex:106`). Space reads: participation (`assert_agent_in_space/2`, `tool_surface.ex:15431`). Page writes: the Historian pin only (`routing.ex:294`). Owner: `agent_runtimes.owner_user_id` for federated agents (`agent_runtime.ex:58`). None for `built_in` (`agent.ex:85`). | Effective set = the agent's own grants ∩ its owner's, inheriting the owner's by default. On day one, an agent's own grants are the translation of its current bundles, so every runtime's `tools/list` is unchanged. The current Historian keeps its page-write reach. The ownerless built-in case is decided in the second pass. |
| 8 | **Meeting invitee** (unauthenticated) | The `meet.` host, `:guest_browser` pipeline (`router.ex:83-90`, no `:require_auth`), and the `:guest_meeting` live_session (`router.ex:760`). The bearer is a slug+token pair checked by `Meetings.resolve_guest_invite/2` (`lib/platform/meetings.ex:1701`), and the token lives 30 minutes (`meetings.ex:4281`). There is no user row and no membership. | **No role and no `%Scope{}`.** This actor is not a principal in RBAC v2. It stays a token capability for one meeting room. |

**"Guest" means two things, so the meeting actor gets a different name.** The built-in role
**guest** (row 5) is a signed-in user with a user row, an org membership and space grants. The
actor in row 8 is called a **meeting invitee** throughout this ADR and in every downstream member:
it is unauthenticated, has no user row, and its access comes from a link token. Code that
touches the `:guest_meeting` live_session, the `:guest` layout or `resolve_guest_invite/2` is
about meeting invitees, and must never read or write the `guest` role.

**Deliberate reversal of rbac-v1 resolved question 9.** The v1 design page
(`project/019d1357-cb08-7023-b165-fd19e9462316/page/architecture/rbac-v1.md`, "Open Questions
Resolved (2026-07-21)", item 9) settled *"No 'guest' role distinction — external users are regular
members with scoped access."* v2 reverses this **in naming and storage, not in behaviour**. The
guest role grants exactly what a v1 external member can do (row 5).

The reason is that v2 makes permission sets data attached to roles. Keeping external as an
orthogonal flag that silently subtracts permissions would leave a second restriction path outside
the model, and that path could not be:
- inspected in the Access panel;
- explained in a denial ("which rule?");
- targeted by an IdP group mapping, which is how `sxi-external` generalizes.

Rows 5 and 6 also show that the flag is enforced unevenly today. `org_admin?/2` honours it.
`root_admin?/1` and `visibility/1` do not, and only the HTTP plug and `ExternalScope` make up the
difference. A named role closes that unevenness by construction. The flag remains as the input
the mapping reads. It stops being the mechanism.

## Bypass surfaces

These surfaces carry or reveal resource data outside the main module views, so a module gate alone
does not cover them. One row per surface. "Today" is main `b75087dd2`. "None today" means the named
module has no viewer, external or visibility check; the grep that confirmed it is given in the row.
The v2 rule column states what each surface must check once `%Scope{}` exists. The resolution
procedure it calls is defined in the second pass.

| Surface | Today's enforcement point | What it checks today | v2 rule |
|---|---|---|---|
| **files-service** | **None needed: it is not a read surface.** Measured on `Startup-Suite/files-service` at `42b43055e1b9` (2026-09-24): `app/main.py` declares only `GET /health` (`:45`, capability probe, no data) and `POST /extract` (`:63`, bytes in → text out, stateless, behind the shared `FILES_SERVICE_TOKEN` bearer, `app/auth.py:27`). It has no storage and no route that returns a stored file. Core's only call is `Platform.Files.ServiceClient.extract/2` (`lib/platform/files/service_client.ex:51`, `/extract` at `:66`). | No user ever reaches it. Every user-facing byte read is served by core: file blobs (`FileBlobController`, `file_blob_controller.ex:57`, `:203-221`), chat attachments (`ChatAttachmentController`, `chat_attachment_controller.ex:7-10`) and prototype bundles (row below). | Enforce on **core's** byte-serving controllers, not on files-service. `FileBlobController` replaces its `root_admin? or member_of?(project.org)` check with `files.read` on the file's project, through the Scope. files-service stays a server-to-server extractor holding no user identity. If it ever gains a read route, that route needs a row here first. |
| **Task-router dispatch** | **None today.** `grep -nE 'external_user\|ExternalScope\|visibility\(\|root_admin\|member_of' lib/platform/orchestration/task_router.ex` returns nothing. The only assignee check is `refresh_assignee/2` (`task_router.ex:2331`), which suppresses dispatch only for `{:error, :user_assignee}` (`:2348`). | Nothing about whether the assigned agent, or its owner, may see the task. An agent owned by an external user can be dispatched onto any task. | Before dispatch, the assignee's effective scope (agent ∩ owner) must hold `tasks.read` on the task. If it does not, dispatch is suppressed, using the same suppress clause `:user_assignee` uses, never by failing open. The denial is posted to the task with the "why and who can grant" shape. |
| **Notifications** | **None today.** `grep -cE 'external\|visibility\|ExternalScope\|external_user' lib/platform/notifications.ex` gives `0`. `fan_out_to_humans/3` (`notifications.ex:44-48`) sends to whatever participant ids the caller passes. `AttentionRouter` pushes to a user directly (`lib/platform/chat/attention_router.ex:916`). | Nothing in the notification layer. Recipients are the caller's choice, which is today a space's participants. | A push carries resource content, so it is a read. Before sending, each recipient must hold read on the resource the payload names (for example `chat.read` on the space, `tasks.read` on the task). A recipient who lacks it is dropped. Notifications stay derived from participation, but participation no longer implies the grant. |
| **Search** | Chat: `Chat.search_messages/3` applies `ExternalScope.scope_by_space_id/2` (`chat.ex:3047`). Memory: `Org.Wiki.Search` post-filters message hits to the calling agent's spaces (`lib/platform/org/wiki/search.ex:1304`), and pages and journals go through `Routing.gate_read/2` (`routing.ex:313`), which drops only private rows. The human UI calls `memory_search` with `agent: nil` (`view.ex:367`), which returns no message hits and unscoped pages. | Chat search: external only. Memory search: agent space membership for messages, private-row ownership for pages, and the optional `org_id` filter. No per-user scope. | Each corpus applies `*.read` through the Scope **before** fusion: page and journal hits by `memory.read` on the node's subtree, message hits by `chat.read` on the space, task hits by `tasks.read`. Filtering after fusion would let ranking reveal hidden rows, and `Wiki.Search` already counts ACL drops in `dropped` (`search.ex:1038-1046`). |
| **Mentions** | `Chat.can_summon_agents?/2` (`chat.ex:5484-5488`) is true for a space-admin participant or the sponsor of the space's task. `admin_add_agent/3` (`:5507`) shares the rule. | Every user. It checks space-participant admin or sponsor, not org role, and does not check whether the agent's owner may see the space. | Summoning needs `chat.manage` (or the space-admin participant role) on the space, **and** the agent's effective scope must hold `chat.read` there. A mention can never widen an agent beyond its owner, and the bounded `history_visible_from` grant stays. |
| **PubSub topics** | **None at the topic layer.** `PlatformWeb.SpaceTopics.hold/3` (`lib/platform_web/space_topics.ex:179`) subscribes whatever space id it is given. `CanvasHooks.find/2` (`lib/platform_web/live/chat/canvas_hooks.ex:337`) resolves any canvas id through `Chat.get_canvas/1`, and `put/2` (`:203`) subscribes to that canvas's topic. | The callers decide. ChatLive admits a space through `ExternalScope.authorized_space?/2` (externals) or the implicit-join kinds (internals) before holding its topic. The canvas hook has no check. | Subscribing is reading. Every `subscribe` goes through a Scope check on the topic's resource (`chat.read` on the space, read on the canvas), in one helper that `SpaceTopics` and `CanvasHooks` both call. A grant change broadcasts an invalidation that makes held topics re-check and drop (live apply, second pass). |
| **Presence** | `Chat.Presence.list_online_for_viewer/1` (`lib/platform/chat/presence.ex:223`) reads only spaces from `Chat.list_viewer_presence_space_ids/1` (`chat.ex:611-616`), which is participation fenced by `Tenancy.visibility/1`. | Every user, by participation ∩ org visibility. For an external user, `:root_all` makes the org fence a no-op (see premises), so participation alone bounds it. | Presence is a read on the space: a viewer sees a person online only in spaces where the viewer holds `chat.read`. Same seam, with the Scope replacing `visibility/1`. |
| **Attachments** | HTTP: the `:attachment_auth` pipeline (`router.ex:216-219`) runs `PlatformWeb.Plugs.AttachmentAuth`, then `ChatAttachmentController.show/2` (`router.ex:230`) calls `Chat.get_visible_attachment_for_principal/2` (`chat.ex:4963-4980`). That function requires space membership (`principal_is_member?/2`, `:4998`) and refuses nil-space rows to external principals (`:4976`). Upload: the M9 check `require_user_member/2` (`lib/platform/chat/attachments/tool_handlers.ex:370-377`) uses `ExternalScope` for external users and `Chat.user_in_space?/2` for others. A second agent gate sits at `tool_handlers.ex:392`. | Every user (space membership), with the extra nil-space refusal for external users only. | Download needs `chat.read`, and upload needs `chat.write`, on the attachment's space through the Scope. An attachment linked to a canvas or task inherits from that resource. A nil-space row needs root admin. The duplicate agent gate at `tool_handlers.ex:392` folds into the same check. |
| **Canvases** | `Platform.Chat.CanvasAccess.fetch_for_viewer/3` (`lib/platform/chat/canvas_access.ex:234`) and `fetch_for_writer/2` (`:273`). They check participation first, then org reach (`:org_reader`, root admin or `member_of?`, `:488`). External users skip org reach (`:343`). | Every user. Participation or org reach, and external users get participation only. | `canvas` read and write through the Scope. A canvas inherits from its space and from the task it is attached to, and a deny on either wins. `fetch_for_viewer/3` and `fetch_for_writer/2` are rewritten to consume `%Scope{}`; no second gate is added next to them. `CanvasHooks.find/2` goes through `fetch_for_viewer/3`. |
| **Prototype grants** | `PrototypeController.serve/2` (`lib/platform_web/controllers/prototype_controller.ex:167-172`) verifies the signed grant for this prototype and version, then re-checks `Tenancy.member_of?/2` of the prototype's org for the grant's user on every request. The grant route runs without `:require_auth` (`router.ex:792-796`). Minting goes through `session_member?/2` (`:252-256`) behind `:enforce_external_scope` (`router.ex:801`). | Every user, by org membership. `member_of?/2` counts external rows (`tenancy.ex:1139-1145` has no `external` filter), so an external member of the org passes the per-request re-check. Minting is blocked for them by the HTTP plug. | Each request re-checks `prototypes.read` on the prototype (resource-scoped, inheriting from the org or project) for the grant's user, through the Scope. Revoking the grant revokes the URL on the next request, as membership removal does today. |
| *External HTTP fast-fail* (added) | `PlatformWeb.Plugs.ExternalUserScope` (`external_user_scope.ex:54`, allowlist `gate_external/2` at `:76-147`), applied by the `:enforce_external_scope` pipeline (`router.ex:178-180`). | External users only. Internal users pass through unchanged. | Kept as the fast-fail for the guest role's HTTP surface. It is not the authorization: a live navigation inside one live_session never re-runs an HTTP plug (`router.ex:882-893`), so module gates also run in `on_mount`. |
| *File blobs* (added) | `FileBlobController.do_authorize/2` (`file_blob_controller.ex:202-221`): root admin, OR an org-less project, OR `member_of?` the project's org. | Every user, by org membership. This is narrower than `:root_all`: a root-org member who is not a member of the project's org is refused. | `files.read` on the file's project through the Scope (see the files-service row). |

## Decisions

*Recorded in the second pass of this ADR: permission model; built-in roles; levels and inheritance;
precedence and the resolution procedure; memory grants (node anchoring as settled by member 3, as
summarised under the measured premises above); agents and the owner cap; delegation and audit;
root-admin carve-outs; IdP groups to roles; UX; denial shape; the "not Byzantine" design rule; the
per-member build map; open questions and consequences.*
