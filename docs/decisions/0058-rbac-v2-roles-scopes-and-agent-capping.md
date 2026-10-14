# ADR 0058: RBAC v2 — Roles, Scopes, and Agent Capping

**Status:** Proposed
**Date:** 2026-10-14
**Owners:** Rowan, Dalton
**Task:** `01a1386d-a18f-7001-9faa-04316dc0198c` (stack `rbac-roles`, `01a1386d-6d34-7001-9f93-b1428a6b0604`, position 1)
**Design source:** Rowan's settlement on 2026-10-14 in space `019f4882-c8d1-724e-a89e-ecb17d2681c8` (#RBAC System), and prototype canvas `01a1384a-3317-7001-ace5-45c7ef34f08e` ("Access — agent-first prototype").
**Amends (in part, not superseded):** the *authorization* role of capability bundles in `0034-mcp-endpoint-and-capability-bundles.md § Capability bundles` (bundles stop being the thing that grants a tool; see § Agents below), and the Historian-only page-write rule in `0041-org-memory-v2-wiki-system.md § Historian as sole page writer` (a subtree `memory.write` grant replaces it for agents). Everything else in both ADRs stands.
**Related:** `0042-org-project-topology-and-context-inheritance.md § 3. Context inheritance rules` (the org → project → space tree that grants inherit along), `0040-federated-agent-owner-identity.md § D2. What scope does ownership confer?` (the owner question this ADR answers for authorization), `0057-prototypes-on-suite.md` (prototype grants, one of the bypass surfaces). Runbook for the v1 model: `docs/runbooks/external_users.md`.

The Context section records the falsifier check, the measured premises, the mapping from today's
state onto built-in roles, and the bypass-surface table. The Decisions section (permission model,
built-in roles, inheritance, precedence, memory grants, agents, delegation, root-admin carve-outs,
IdP mapping, UX, denials, the per-member build map, open questions and consequences) builds on
those tables.

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
  (`:178`). So **a built-in agent has no owner today.** Its cap is decided in § Agents.

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

  § Memory grants records the decision.

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
| 7 | **Agent** | Tools: `allowed_bundles` through `ToolAuthorization.authorize/2` (`tool_authorization.ex:106`). Space reads: participation (`assert_agent_in_space/2`, `tool_surface.ex:15431`). Page writes: the Historian pin only (`routing.ex:294`). Owner: `agent_runtimes.owner_user_id` for federated agents (`agent_runtime.ex:58`). None for `built_in` (`agent.ex:85`). | Effective set = the agent's own grants ∩ its owner's, inheriting the owner's by default. On day one, an agent's own grants are the translation of its current bundles, so every runtime's `tools/list` is unchanged. The current Historian keeps its page-write reach. The ownerless built-in case is decided in § Agents. |
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
procedure it calls is defined in § Precedence. Where a member plan builds a surface differently
(member 7 runs its checks in conjunction with the existing ones rather than replacing them), the
member's choice is recorded in § Per-member build map.

| Surface | Today's enforcement point | What it checks today | v2 rule |
|---|---|---|---|
| **files-service** | **None needed: it is not a read surface.** Measured on `Startup-Suite/files-service` at `42b43055e1b9` (2026-09-24): `app/main.py` declares only `GET /health` (`:45`, capability probe, no data) and `POST /extract` (`:63`, bytes in → text out, stateless, behind the shared `FILES_SERVICE_TOKEN` bearer, `app/auth.py:27`). It has no storage and no route that returns a stored file. Core's only call is `Platform.Files.ServiceClient.extract/2` (`lib/platform/files/service_client.ex:51`, `/extract` at `:66`). | No user ever reaches it. Every user-facing byte read is served by core: file blobs (`FileBlobController`, `file_blob_controller.ex:57`, `:203-221`), chat attachments (`ChatAttachmentController`, `chat_attachment_controller.ex:7-10`) and prototype bundles (row below). | Enforce on **core's** byte-serving controllers, not on files-service. `FileBlobController` replaces its `root_admin? or member_of?(project.org)` check with `files.read` on the file's project, through the Scope. files-service stays a server-to-server extractor holding no user identity. If it ever gains a read route, that route needs a row here first. |
| **Task-router dispatch** | **None today.** `grep -nE 'external_user\|ExternalScope\|visibility\(\|root_admin\|member_of' lib/platform/orchestration/task_router.ex` returns nothing. The only assignee check is `refresh_assignee/2` (`task_router.ex:2331`), which suppresses dispatch only for `{:error, :user_assignee}` (`:2348`). | Nothing about whether the assigned agent, or its owner, may see the task. An agent owned by an external user can be dispatched onto any task. | Before dispatch, the assignee's effective scope (agent ∩ owner) must hold `tasks.read` on the task. If it does not, dispatch is suppressed, using the same suppress clause `:user_assignee` uses, never by failing open. The denial is posted to the task with the "why and who can grant" shape. |
| **Notifications** | **None today.** `grep -cE 'external\|visibility\|ExternalScope\|external_user' lib/platform/notifications.ex` gives `0`. `fan_out_to_humans/3` (`notifications.ex:44-48`) sends to whatever participant ids the caller passes. `AttentionRouter` pushes to a user directly (`lib/platform/chat/attention_router.ex:916`). | Nothing in the notification layer. Recipients are the caller's choice, which is today a space's participants. | A push carries resource content, so it is a read. Before sending, each recipient must hold read on the resource the payload names (for example `chat.read` on the space, `tasks.read` on the task). A recipient who lacks it is dropped. Notifications stay derived from participation, but participation no longer implies the grant. |
| **Search** | Chat: `Chat.search_messages/3` applies `ExternalScope.scope_by_space_id/2` (`chat.ex:3047`). Memory: `Org.Wiki.Search` post-filters message hits to the calling agent's spaces (`lib/platform/org/wiki/search.ex:1304`), and pages and journals go through `Routing.gate_read/2` (`routing.ex:313`), which drops only private rows. The human UI calls `memory_search` with `agent: nil` (`view.ex:367`), which returns no message hits and unscoped pages. | Chat search: external only. Memory search: agent space membership for messages, private-row ownership for pages, and the optional `org_id` filter. No per-user scope. | Each corpus applies `*.read` through the Scope **before** fusion: page and journal hits by `memory.read` on the node's subtree, message hits by `chat.read` on the space, task hits by `tasks.read`. Filtering after fusion would let ranking reveal hidden rows, and `Wiki.Search` already counts ACL drops in `dropped` (`search.ex:1038-1046`). |
| **Mentions** | `Chat.can_summon_agents?/2` (`chat.ex:5484-5488`) is true for a space-admin participant or the sponsor of the space's task. `admin_add_agent/3` (`:5507`) shares the rule. | Every user. It checks space-participant admin or sponsor, not org role, and does not check whether the agent's owner may see the space. | Summoning needs `chat.manage` (or the space-admin participant role) on the space, **and** the agent's effective scope must hold `chat.read` there. A mention can never widen an agent beyond its owner, and the bounded `history_visible_from` grant stays. |
| **PubSub topics** | **None at the topic layer.** `PlatformWeb.SpaceTopics.hold/3` (`lib/platform_web/space_topics.ex:179`) subscribes whatever space id it is given. `CanvasHooks.find/2` (`lib/platform_web/live/chat/canvas_hooks.ex:337`) resolves any canvas id through `Chat.get_canvas/1`, and `put/2` (`:203`) subscribes to that canvas's topic. | The callers decide. ChatLive admits a space through `ExternalScope.authorized_space?/2` (externals) or the implicit-join kinds (internals) before holding its topic. The canvas hook has no check. | Subscribing is reading. Every `subscribe` goes through a Scope check on the topic's resource (`chat.read` on the space, read on the canvas), in one helper that `SpaceTopics` and `CanvasHooks` both call. A grant change broadcasts an invalidation that makes held topics re-check and drop (live apply, § Delegation and audit). |
| **Presence** | `Chat.Presence.list_online_for_viewer/1` (`lib/platform/chat/presence.ex:223`) reads only spaces from `Chat.list_viewer_presence_space_ids/1` (`chat.ex:611-616`), which is participation fenced by `Tenancy.visibility/1`. | Every user, by participation ∩ org visibility. For an external user, `:root_all` makes the org fence a no-op (see premises), so participation alone bounds it. | Presence is a read on the space: a viewer sees a person online only in spaces where the viewer holds `chat.read`. Same seam, with the Scope replacing `visibility/1`. |
| **Attachments** | HTTP: the `:attachment_auth` pipeline (`router.ex:216-219`) runs `PlatformWeb.Plugs.AttachmentAuth`, then `ChatAttachmentController.show/2` (`router.ex:230`) calls `Chat.get_visible_attachment_for_principal/2` (`chat.ex:4963-4980`). That function requires space membership (`principal_is_member?/2`, `:4998`) and refuses nil-space rows to external principals (`:4976`). Upload: the M9 check `require_user_member/2` (`lib/platform/chat/attachments/tool_handlers.ex:370-377`) uses `ExternalScope` for external users and `Chat.user_in_space?/2` for others. A second agent gate sits at `tool_handlers.ex:392`. | Every user (space membership), with the extra nil-space refusal for external users only. | Download needs `chat.read`, and upload needs `chat.write`, on the attachment's space through the Scope. An attachment linked to a canvas or task inherits from that resource. A nil-space row needs root admin. The duplicate agent gate at `tool_handlers.ex:392` folds into the same check. |
| **Canvases** | `Platform.Chat.CanvasAccess.fetch_for_viewer/3` (`lib/platform/chat/canvas_access.ex:234`) and `fetch_for_writer/2` (`:273`). They check participation first, then org reach (`:org_reader`, root admin or `member_of?`, `:488`). External users skip org reach (`:343`). | Every user. Participation or org reach, and external users get participation only. | `canvas` read and write through the Scope. A canvas inherits from its space and from the task it is attached to, and a deny on either wins. `fetch_for_viewer/3` and `fetch_for_writer/2` are rewritten to consume `%Scope{}`; no second gate is added next to them. `CanvasHooks.find/2` goes through `fetch_for_viewer/3`. |
| **Prototype grants** | `PrototypeController.serve/2` (`lib/platform_web/controllers/prototype_controller.ex:167-172`) verifies the signed grant for this prototype and version, then re-checks `Tenancy.member_of?/2` of the prototype's org for the grant's user on every request. The grant route runs without `:require_auth` (`router.ex:792-796`). Minting goes through `session_member?/2` (`:252-256`) behind `:enforce_external_scope` (`router.ex:801`). | Every user, by org membership. `member_of?/2` counts external rows (`tenancy.ex:1139-1145` has no `external` filter), so an external member of the org passes the per-request re-check. Minting is blocked for them by the HTTP plug. | Each request re-checks `prototypes.read` on the prototype (resource-scoped, inheriting from the org or project) for the grant's user, through the Scope. Revoking the grant revokes the URL on the next request, as membership removal does today. |
| *External HTTP fast-fail* (added) | `PlatformWeb.Plugs.ExternalUserScope` (`external_user_scope.ex:54`, allowlist `gate_external/2` at `:76-147`), applied by the `:enforce_external_scope` pipeline (`router.ex:178-180`). | External users only. Internal users pass through unchanged. | Kept as the fast-fail for the guest role's HTTP surface. It is not the authorization: a live navigation inside one live_session never re-runs an HTTP plug (`router.ex:882-893`), so module gates also run in `on_mount`. |
| *File blobs* (added) | `FileBlobController.do_authorize/2` (`file_blob_controller.ex:202-221`): root admin, OR an org-less project, OR `member_of?` the project's org. | Every user, by org membership. This is narrower than `:root_all`: a root-org member who is not a member of the project's org is refused. | `files.read` on the file's project through the Scope (see the files-service row). |

## Decisions

The sections below are the decisions. Each one has a heading that a stack member can cite from
code as this file plus `§ <heading>`. Unless a sentence says otherwise, a decision describes what
the approved member plans build. Where a member plan's choice differs from the brief this ADR was
written against, the member's choice is recorded here and the difference is noted, because each
member executes against its own approved plan. Code paths are relative to `apps/platform/` and
were read on main `b75087dd2`. Function names in `Platform.Access` belong to the member plans and
do not exist on main yet.

**One owner.** `Platform.Access` (`lib/platform/access.ex` and `lib/platform/access/`) is the one
module that answers "may this actor do this here". It owns:
- the decision functions `can?/3`, `permitted_ids/2`, `check/3`, `holds_anywhere?/2`,
  `module_access?/3`, `holds_role?/3`, `authorize/3` and `authorize_install/1`;
- `Platform.Access.Query`, the only place a decision becomes an Ecto condition
  (`where_permitted/5`, plus `restrict/5`, which short-circuits it);
- every authorization table. Each one is named `access_*`: `access_roles`, `access_grants`,
  `access_grant_changes`, `access_runtime_profiles`, `access_role_assignments`,
  `access_space_restrictions`, `access_idp_group_roles` and `access_change_proposals`.

`Platform.Roles` is the agent responsibility system (the Historian pin and its peers) and holds
none of this. `Platform.Org.Wiki.Nodes` owns memory *identity* (§ Memory grants) and decides no
permission.

## Permission model

**A permission is a `module.action` string, scoped to `:all` or to a list of resource ids.**
Every permission matches `^[a-z_]+\.[a-z_]+$` and is declared in `Platform.Access.Registry` by the
module that owns it. Build-time modules declare theirs through an optional `permissions/0`
callback on `Platform.Extension` (`lib/platform/extension.ex`).

The vocabulary below is the one the member plans name. A module may add actions; it may not
reuse another module's prefix.

| Module | Permissions | Notes |
|---|---|---|
| chat | `chat.read`, `chat.write`, `chat.manage` | `chat.manage` is summoning agents and space administration. |
| tasks | `tasks.read`, `tasks.write`, `tasks.manage`, `tasks.promote` | `tasks.manage` is the pipeline-health view (install-wide data, so it needs `:all`). `tasks.promote` is quarantine promotion (`tasks.ex:7378-7379`). |
| files | `files.read`, `files.write` | |
| memory | `memory.read`, `memory.write`, `memory.journal` | `memory.write` is a page write and takes memory-node resources (§ Memory grants). `memory.journal` is a journal append. |
| canvases | `canvas.read`, `canvas.write` | |
| meetings, mail | `meetings.join`, `mail.use`, `mail.manage` | `mail.manage` is today's org-admin mail-account management (`mail.ex:61`). |
| prototypes | `prototypes.read`, `prototypes.publish` | |
| experiments | `experiments.read`, `experiments.propose` | Human launch, stop and conclude stay install-level (§ Root-admin carve-outs). |
| agents | `agents.manage_own`, `agents.manage_all` | § Agents. |
| skills, vault, prompts | `skills.read`, `skills.write`, `vault.use`, `prompts.read`, `prompts.manage` | `vault.use` lets a tool be listed. Which secret it reaches is still decided by the vault's own grants (§ Root-admin carve-outs). |
| access | `access.manage` | § Delegation and audit. |
| install | `install.admin` | The one install-level permission, flagged `install_level: true` in the registry. No role carries it and no grant may name it. |

**Two kinds of permission are never granted by a built-in role:**
- `install.admin`: install-level, never grantable;
- the *module-admin* permissions `tasks.manage` and `prompts.manage`. With no grants they are held
  only through the root-admin rule (§ Built-in roles). Unlike `install.admin`, they can be granted.

**One `%Platform.Access.Scope{}` per actor, built once per request and once per socket.** Member
2's struct is `%Scope{actor, org, permissions}`, where `permissions` is
`%{permission => :all | [resource_id]}`. This ADR names exactly two more fields, and no others:
- `grants`: member 3's build-time snapshot of the `access_grants` rows for the actor's
  principals;
- `role_keys`: member 8's `%{org_id => MapSet}` of base and assigned role keys.

The builders are:
- `Scope.for_user/1`, which is fail-closed for `nil`;
- `Scope.for_runtime/1`, capped at the owner (§ Agents);
- `Scope.for_role/2`, used by view-as;
- `Scope.for_meeting_invitee/1`, which is empty;
- `Scope.system/0`, the only unrestricted scope.

`LiveAuth.on_mount(:default)` (`live_auth.ex:36`) and `RequireAuth.call/2` assign it as
`:access_scope`. It holds two build-time snapshots, the grants and the guest's participant spaces.
Long-lived sockets therefore filter guest chat through the live `member_space_ids/1` subquery
(`external_scope.ex:96`), not through the snapshot, and member 6 rebuilds the assign over PubSub
when a grant changes (§ Delegation and audit).

**`Scope` generalizes `Platform.Chat.ExternalScope`; it does not replace it.** Each existing seam
gets one ruling. None of them gains a second gate:

| Seam today | v2 ruling | Member |
|---|---|---|
| `ExternalScope.scope_spaces/2`, `scope_by_space_id/2`, `visible_space_id?/2`, `member_space_ids/1` | Gain `%Access.Scope{}` clauses. A guest Scope filters through the same live subquery. `for_user/1` keeps returning `%ExternalScope{}`, because `chat_live.ex:345` and `chat/context_summary.ex:150` pattern-match the struct, and a `%Scope{}` there would hand guests the unscoped archived list. | 2, 3 |
| `ExternalScope.authorized_space?/2` (`external_scope.ex:164`) | Unchanged. It is the admission branch that carries the per-org DM allowlist. | 2 |
| `ToolAuthorization.authorize/2` and `effective_tools/1` (`tool_authorization.ex:106`, `:75`) | Kept as the one entry point every transport calls. Both delegate to `Platform.Access.Tools`. | 5 |
| `CanvasAccess.fetch_for_viewer/3` (`canvas_access.ex:234`) | Consults `Access.can?/3` when `:access_scope` is given, so a denied canvas answers like a missing one. `fetch_for_writer/2` (`:273`) is unchanged in this stack. | 3 |
| `Chat.SpaceAccess.authorize_writer/2` (`space_access.ex:132`) | **Not rewritten by any member.** It stays participation-based, and `chat.write` on a space is decided there until a follow-up folds it into Access (Open question 4). | none |
| `Wiki.Routing.gate_write/3` (`routing.ex:294`) | Rewritten to ask Access (§ Memory grants), but **no member plan builds this** (Open question 3). | none |
| `LiveAuth.on_mount(:ensure_admin)` (`live_auth.ex:47`) | Replaced by `PlatformWeb.ModuleGate`. | 4 |
| `Tenancy.root_admin?/1` re-checks inside contexts (`branding.ex:362`, `prototypes/settings.ex:64`, `tenancy/lifecycle.ex:1173`, `vault/shared.ex:365`, `sign_in_admin.ex:433`) | Replaced by `Access.authorize_install/1`. | 4 |

**Rail rule.** The rail shows a module when the actor holds that module's rail permission
*anywhere*: `permitted_ids/2` is `:all`, or its allow set minus its deny set is non-empty
(`Access.holds_anywhere?/2`, member 4). A guest scope also needs the registry entry to carry
`guest_admissible: true`. On day one only `:chat` carries it. Member 4 turns `:tasks` on only after
every Tasks write entry point re-checks permission. The flag exists because a guest admitted into
a module whose LiveView reads are not yet Scope-filtered would see everything in it.

## Built-in roles

**The built-in roles are admin, member and guest, stored as rows in `access_roles`** with
`builtin: true`. A role maps each permission to a grant rule. Grant rules are data, and there are
three values:
- `"all"`;
- `"membership_org"`, meaning the org of the membership that carries the role;
- `"participant_spaces"`, meaning the actor's `chat_participants` spaces.

A role cannot store a resource id, because admin and member are relative to the membership's org.
**A role carries no deny.** Deny is a row in `access_grants` (§ Precedence). A deny can target a
role principal, which is how a deny applies to every guest.

`org_memberships.access_role_key` is a **generated** column:
`CASE WHEN external THEN 'guest' ELSE role END STORED` (member 2). It cannot drift from the 13
writers of `org_memberships` that member 2 counted. `role` and `external` stay the source of truth.

**Two rules are code, not role data.** Each is a named function so that tests can mutate it:
- **Root-org widening.** A membership in a root org at any role widens org and project visibility
  to `:all`. This reproduces `Tenancy.visibility/1` returning `:root_all` (`tenancy.ex:549-574`).
- **Root admin.** A non-guest `admin` membership in a root org grants `install.admin` and the
  module-admin permissions. This is the root-admin bypass. It is never part of the built-in
  `admin` role, so a sub-org admin never holds it.

**Guest dominates.** If any of the actor's memberships maps to `guest`, the guest restrictions
apply to the whole actor. This reproduces `Tenancy.external_user?/1` (`tenancy.ex:817-821`), which
is by-user, not by-org. In particular, **the root-admin rule never fires for a user with any
external row** (mapping table row 6). Today an external root admin is held off `/admin` only by
the `ExternalUserScope` plug, because `root_admin?/1` ignores `external`
(`tenancy.ex:1106-1116`). Under v2 that defence becomes part of the model. § Root-admin
carve-outs repeats the rule for each install-level surface.

**The invariant: no behaviour change.** The day-one permission sets are the ones the stage-1
mapping table ("Today's state mapped onto built-in roles") derives, one actor class per row. That
table is the oracle. Member 2's equivalence test checks the derived sets against today's code
paths for every actor class. If this section and that test disagree, the test wins and this ADR
is amended. In outline:
- **`member`** holds:
  - `chat.read` and `chat.write` at `:all` (internal chat is pass-through today);
  - `tasks.read` and `tasks.write` at `:all`. The Tasks board is not viewer-scoped
    (`board_hooks.ex:207`), and this mapping deliberately keeps that;
  - `memory.read`, `memory.write` and `memory.journal` at `:all`, because human edits are ungated
    today (`org_memory_live/view.ex:674`, `:1129`);
  - `files.read` and `files.write` under `membership_org`, reproducing the blob controller's
    narrower rule (`file_blob_controller.ex:217`);
  - `canvas.read` and `canvas.write` under participation or `membership_org` org reach;
  - `prototypes.read` under `membership_org`;
  - `experiments.read`, `experiments.propose`, `agents.manage_own`, `skills.read`, `skills.write`,
    `vault.use`, `prompts.read`, `meetings.join` and `mail.use`.
- **`admin`** holds everything `member` holds, plus four permissions under `membership_org`:
  - `access.manage` (member 6);
  - `mail.manage`;
  - `prototypes.publish`, for the `"admins"` policy (`prototypes.ex:208`);
  - `tasks.promote`.

  The planner default in member 5 also gives it `agents.manage_all` under `membership_org`,
  resolved against the target runtime owner's non-external memberships.
- **`guest`** holds `chat.read` **and** `chat.write`, both under `participant_spaces`. Write is
  included because today an external user posts, uploads and downloads in their own spaces
  (rbac-v1 resolved questions 3 and 4). A `chat.read`-only guest would be a behaviour change.
  The per-org DM allowlist stays the admission branch of `authorized_space?/2`. Guest holds
  nothing else.

"External becomes guest plus space grants" therefore means **guest plus `chat.read` and
`chat.write` on each participant space**, carried by the `participant_spaces` rule and not by one
`access_grants` row per space. Today's gaps carry over unchanged, as the mapping table says (the
unscoped board, and `CanvasHooks.find/2` resolving any canvas id). The members that narrow them,
and how far, are listed in § Per-member build map.

**Custom roles** (member 8) are rows in the same table with an `org_id` and the key
`"custom:" <> uuidv7`, so their keys never collide with a built-in key. They are named permission
sets that use the same three grant rules. They may not carry `install.admin`. **The base role
stays derived:** extra roles are additive `access_role_assignments` rows (`source` is `manual` or
`idp`). Member 2's moduledoc forecasts converting `access_role_key` into an assignable column;
member 8's plan does not do that, and member 8's choice is the decision. Built-in roles cannot be
assigned through an assignment row, because the base role comes from the membership. A guest may
hold a custom role's key, but the role's permissions do not widen a guest.

## Levels and inheritance

There are four levels:
- **module**: the rail and `ModuleGate` (member 4);
- **project**: resource type `project`;
- **channel or space**: resource types `space` and `canvas`;
- **org-memory subtree**: resource type `memory_node`.

Member 3's `access_grants.resource_type` CHECK admits exactly `project`, `space`, `canvas` and
`memory_node`. Canvas is a resource type because the acceptance case is "a deny on one canvas".

**Linked resources inherit by default, and inheritance flows downward only.** These are the
edges:
- project P → its tasks (`tasks.project_id`);
- project P → those tasks' execution spaces (`chat_spaces.kind = 'execution'`, joined through
  `metadata->>'task_id'`, compared as text and not cast to uuid);
- project P → the canvases in those spaces, and the canvases attached to P's tasks
  (`task_canvas_attachments`);
- project P → stacks with `task_stacks.project_id = P`. Members of those stacks that sit in P are
  covered by the task edge;
- space S → canvases whose `space_id` is S. Member 3 lists the canvas edges only below a project;
  this ADR also requires the direct space-to-canvas edge, so a deny or a role restriction on a
  channel covers its canvases. Member 8 already applies restrictions downward this way;
- memory node N → every node and page under N's current path (§ Memory grants).

**Nothing flows upward.** A grant on a space or canvas never widens to its project or tasks, and
a grant on a child node never widens to its parent. Granting U the execution space of a task in R
gives U no task in R. A role restriction on a space is a property of that space and also
inherits downward.

## Precedence

**An explicit deny wins over inherited access and over a grant that arrives by another path.**
`Platform.Access` evaluates `can?(scope, permission, resource)` with this ordered procedure. Every
step ends in a single answer; there is no tie-break left unstated.

1. **Install level.** If `permission` is `install.admin`, permit exactly when the scope carries the
   root-admin rule (non-guest), and stop. No grant, role or restriction is consulted.
2. **Agent cap.** If the actor is an agent, run steps 3 to 7 twice: once for the agent's own
   permissions and grants, and once for its owner's `Scope.for_user/1`. Permit only if **both**
   permit. When it is the owner half that refuses, the denial rule is `capped_at_owner`.
   Member 5 implements this as `Scope.intersect/2` inside `for_runtime/1`: allows intersect,
   denies union, and guest is inherited from the owner. That gives the same answer as running the
   procedure twice. An ownerless agent is capped as § Agents says.
3. **Collect the denies.** Gather every `effect = 'deny'` row whose principal is the actor's user
   id, the actor's agent id, or any role key the actor holds in the resource's org, **and** whose
   resource is the resource itself or any ancestor on a downward edge from § Levels and
   inheritance.
4. **Any deny → refuse** (rule `deny`). A deny on project P therefore refuses every task,
   execution space and canvas below P, whatever allows exist elsewhere.
5. **Role restriction → refuse** (rule `restricted`). If the resource is a restricted space, or
   a canvas in one, and `holds_role?(scope, keys, space.org_id)` is false, refuse. Holding a key in
   an ancestor org counts. Restriction rows are read at decision time; they are not snapshotted.
   A restriction beats every allow, including a direct user grant on that space (member 8).
6. **Allow.** Permit if a role rule grants `permission` over the resource (`all`,
   `membership_org` or `participant_spaces`), or if an `effect = 'allow'` row of the actor's
   principals names the resource or any ancestor on a downward edge.
7. **Otherwise refuse** (rule `not_granted`).

`permitted_ids/2` and `Access.Query.where_permitted/5` implement the same procedure as set and
query forms. Member 3's set-equality test is what keeps the three from drifting. Member 3's own
four-step order corresponds to steps 3, 4, 6 and 7. Steps 1, 2 and 5 are members 2, 5 and 8, and
member 8 places its restriction step with the deny step, as here.

**The grant-less short-circuit.** Member 7's `Access.check/3` returns `:ok` for a scope with no
grants, and member 7's checks run in conjunction with each surface's existing check. That holds
"no grants means today's behaviour" by construction. **But it skips step 5:** a role restriction
is a rule on the channel, not a grant on the actor, so a member who holds no grants would pass
`check/3` on a restricted channel. The decision: **the short-circuit is valid only when the scope
holds no grants AND no `access_space_restrictions` row covers the resource.** That costs one
indexed lookup by `space_id`. Whichever of members 7 and 8 lands second makes `check/3` honour
it. The conflict is recorded in Open questions.

**Deny shape.** A deny is a row in the same `access_grants` table, with `effect = 'deny'`.
A unique index over (principal, permission, resource) means one tuple cannot be both an allow and
a deny. A deny on a role principal applies to every holder of that role. Built-in and custom role
rows never carry a deny.

**The root-admin bypass does not read past a deny.** Root admin skips step 1 and is authorized for
every delegation change (§ Delegation and audit). A deny on a root admin's own user principal
still refuses that admin's reads at step 4. They can remove it, and the removal is then a
ledgered change with `bypass: "root_admin"`. Every bypass is a recorded change, never a silent
read.

### Worked examples

**(a) A deny on project P, while user U holds a direct grant on the execution space C of a task
in P.**
- Step 3 collects the deny on P, because P → task → C is a downward edge.
- Step 4 refuses.
- **U cannot read C.** The rule is `deny`. The direct allow on C is never reached, because a deny
  beats a grant from another path.

**(b) An owner with `tasks.read` on project X only, whose agent holds `tasks.read :all`, and the
owner also holds a deny on canvas K inside X.**

On day one the built-in `member` role carries `tasks.read :all`, so this owner is one whose base
role does not, for example a guest holding an allow on X.
- **A task in project Y.** The agent half permits (its own `:all`). The owner half reaches step 7
  (no allow on Y) and refuses. Both halves must permit, so the answer is **denied**, with rule
  `capped_at_owner`.
- **A task in X.** Both halves permit, so it is **permitted**.
- **Canvas K.** The owner half refuses at step 4 on the deny on K. Denies union across the cap, so
  the answer is **denied**, with rule `deny`. The agent's own allow cannot override the owner's
  deny.

**(c) Agent A holds a `memory.write` allow on subtree `org/page/eng/`, and a deny on page
`org/page/eng/secret/plan.md`. Then `org/page/eng/` is renamed to `org/page/engineering/`.**

A's owner is an internal member, who holds `memory.write :all`, so the cap does not bite.
- Before the rename, the allow names node N_eng (path `org/page/eng/`) and the deny names node
  N_plan (path `org/page/eng/secret/plan.md`). Grants store node ids, never paths.
- The prefix rename (`Wiki.rename_prefix/3`, member 3) moves N_eng and every node under it,
  including N_plan, to the new paths. No `access_grants` row is rewritten.
- **`org/page/engineering/x.md`:** the ancestors resolve to N_eng at its new path, step 3 finds no
  deny, and step 6 finds the allow on N_eng. **Permitted.** The grant followed the node.
- **`org/page/engineering/secret/plan.md`:** it resolves to N_plan, step 3 finds the deny, and step
  4 **refuses**.
- **A new `org/page/eng/y.md`:** no node covers the old path any more, so A's allow does not cover
  it, and A is refused unless another source grants the write. For a human member, `y.md` is
  still writable through the role rule `memory.write :all`. That is today's behaviour and not
  this grant's.

## Memory grants

**This is settled, not open.** Member 3 (`01a1386d-e528`, plan `01a13aa3-89c2`) settles it, and
member 3's stage 1 STOPS if this section says otherwise.

**A grant anchors to a memory node, not to a path.**
- **The node entity:** `org_memory_nodes` (`id` uuidv7, `org_id`, `workspace_id`) is a location
  identity owned by `Platform.Org.Wiki.Nodes`.
- **Path history:** `org_memory_node_paths` (`node_id`, `path`, `valid_from`, `valid_to`). A partial
  unique index on `(workspace_id, path) WHERE valid_to IS NULL` allows at most one current node
  per location.
- **Page rows are untouched.** `org_wiki_pages` keeps today's semantics:
  - `Wiki.rename_page/3` still upserts the content under the new key and deletes the source row
    (`wiki.ex:678`, `:722`, `:731`);
  - page ids, versions, indexing and the overwrite behaviour do not change.
- **Nodes are created lazily.** A node exists only when a grant needs one: `Access.Grants`
  calls `Nodes.ensure/2` and stores the node id. Nothing is created on page write. A node can name
  a page path or a directory prefix ending in `/`, so the subtree root `org/page/eng/`, which has
  no page row today, gets an identity. Journal, private and `burrow/page/` paths are not nodes.
- **A rename moves the node, and the grants follow.**
  - `Nodes.move/3` runs inside the rename transaction, after the page upsert and the delete
    succeed. It closes the old path interval and opens the new one.
  - For a prefix, it moves every node under the old prefix.
  - Grant rows keep their `resource_id`.
  - `Nodes.resolve(path, at: t)` reads through the interval table, so a feedback row recorded
    before the rename still reaches the node it was about.
- **Deleting a page keeps its node, and its grants stay.** The node is the location. A page
  recreated at that path inherits the node's grants, and the recently-deleted row still resolves.
- **A rename that overwrites an existing page merges the two nodes' grants, and deny still
  wins.**
  - The displaced node's current interval is closed, and its grants are re-pointed to the moved
    node.
  - When the merge produces an allow and a deny on the same tuple, the deny is kept and the allow
    dropped, as an explicit step.
  - A prefix rename (`Wiki.rename_prefix/3`) refuses the whole operation with
    `{:error, {:conflict, paths}}` if any target exists, so a subtree rename never overwrites
    silently. The merge applies to single-page overwrites only.
- `memory_rename` gains a prefix mode when both paths end in `/`. Every page-path call is
  byte-identical to today.

**A grant cascades over the node's subtree** through `Nodes.resolve/2`, which returns the node for
the path itself and for every ancestor prefix. Member 3 filters the memory listings by the node,
never by comparing a path string:
- `memory_search`'s page corpus, before fusion and before `match_count`;
- `memory_view`;
- `org_memory_recently_edited` and `org_memory_recently_deleted`;
- `org_memory_feedback_at_path`, which returns `original_content`, so the leak there is content;
- `Wiki.list_pages/1`.

A denied page answers like an absent one. `org_list_descendants` returns orgs, not pages
(`tool_surface.ex:4689`), so it has nothing to filter. Member 3 adds a guard on its response keys
instead.

**Humans.** `memory.write` is today's editing, now scoped. The built-in `member` and `admin` roles
carry `memory.write :all`, which reproduces today's rule: any authenticated human who gets past
`ExternalUserScope` can edit (`view.ex:674`, `:1129`). Guests carry no memory permission, and
`/org_memory` is not on their HTTP allowlist today (`external_user_scope.ex:147`). A deny on a node
narrows a human's editing below the role default.

**Agents.** A subtree `memory.write` grant lets an agent write a page directly. This replaces the
Historian-only rule (`0041-org-memory-v2-wiki-system.md § Historian as sole page writer`) as
enforced by `Wiki.Routing.gate_write/3` (`routing.ex:294`, which is agent-only;
`page_write_gate/3` at `:326` checks `historian?/1`). The agent rule is evaluated with the § Agents
cap.
- **No page-write capability is lost on day one.** The `memory` bundle translates to
  `memory.read` and `memory.journal`, not `memory.write`. So an existing runtime that cannot write
  pages today still cannot.
- **The current Historian receives nothing new and loses nothing.** The `role_assignments`
  Historian pin (`routing.ex:210-214`) stays a source of `memory.write` over every page namespace.
  It is evaluated at decision time, so when the pin moves to another agent, the write moves with
  it.
- **New runtimes inherit their owner** (§ Agents, member 5's exception 2). A new runtime owned by
  an internal member can therefore write pages its owner can write. This is the intended
  replacement of Historian-only, not a leak.
- **Journal writes stay open** to every agent (`gate_write/3`'s `:journal` clause returns `:ok`).
  **Product-owned `burrow/page/...` stays refused to everyone**, human and agent
  (`wiki.ex:393-397` `check_product_owned/2`; the `write_role: :product` clause of `gate_write/3`).
- **Who builds it:** no approved member plan rewrites `gate_write/3`. Member 3's stage 4 says
  explicitly that the Historian gate is NOT replaced. Until a member does it, the Historian-only
  rule stays as it is on main, which is consistent with no behaviour change. Open question 3.

## Agents

**An agent's effective scope is its own grants intersected with its owner's.** By default it
inherits the owner's. The owner is `agent_runtimes.owner_user_id` (`agent_runtime.ex:58`, required
at `:91`). Member 5 measured it NOT NULL on both installs, with zero dangling owners, on
2026-10-14. `Scope.for_runtime/1` returns `Scope.intersect(own, Scope.for_user(owner))`:
- allows intersect;
- denies union;
- the result is guest when the owner is guest;
- `install.admin` is held only if both sides hold it.

Every existing caller of `for_runtime/1` inherits the cap with no edit. These include member 3's
listing tools, member 6's delegation and view-as, member 7's dispatch and mention checks, and
member 8's agent read gate. Member 7's separate owner half (`agent_may_read_space?/2`, the owner
check behind `:owner_denied`) becomes redundant once the cap lands; whichever lands second deletes
it, so only one path enforces the owner cap.

- **`own`**: `access_runtime_profiles.restricted_permissions` (member 5).
  - NULL means "inherit the owner": every registry permission, intersected with the owner's.
  - Otherwise it is a map of permission → `"all"`, which can only narrow.
  - Member 3's agent-principal grants add to it.
- **"Restrict this agent"** is the Control Center toggle that writes that map. It lists only
  permissions the owner holds.

**The ownerless agent cap (decided).** `agents` rows carry no owner field (`agent.ex:72-99`). A
`runtime_type: "built_in"` agent (`:85`) has no runtime, and neither does a `kind: "external"`
HTTP agent. Measured: such agents never reach the MCP catalogue. A built-in agent runs
`Platform.Agents.ToolRunner`'s own function list (`tool_runner.ex:27`, `tool_definitions/0`:
`shell_exec`, `file_read`, `file_write`, `web_fetch`, `canvas_create`, `canvas_update`), and
nothing in that file calls `ToolAuthorization`. **Ownerless agents are capped at the built-in
`member` permission set of the root org.** That means:
- never `install.admin`, a module-admin permission, `access.manage` or `agents.manage_*`;
- any agent-principal deny still applies.

This is no behaviour change: an ownerless agent's Suite reach today is bounded by space
participation, and that is inside `member`. Managing an ownerless agent needs `agents.manage_all`:
- creating one;
- releasing a responsibility pin it holds;
- editing its configuration.

Member 5 builds that rule (`Access.Agents.may_create_ownerless?/1`). It narrows today's open
Control Center on purpose (member 5's exception 1). No member builds a Scope for an ownerless
agent yet, because `for_runtime/1` takes a runtime. The cap is the rule the first such builder
must use.

**MCP bundles stop being the authorization.** Each tool declares a required permission in
`Platform.Access.ToolPermissions` (member 5). For example, `task_update` → `tasks.write`,
`vault_fetch` → `vault.use`, `experiment_start` → `experiments.propose`, `prompt_template_update`
→ `prompts.manage`.
- An undeclared tool is denied. No tool permission may be `install.admin`.
- `tools/list` and every `tools/call` are checked by the same function, because
  `ToolAuthorization.authorize/2` and `effective_tools/1` delegate to `Platform.Access.Tools`.
- **`suite_run` inner calls are checked too.** Structurally they already are: `CodeMode.Bindings`
  reloads the runtime and calls `ToolCall.invoke/4` per inner call, which calls `authorize/2`
  (`code_mode/bindings.ex:113`, `federation/tool_call.ex:75`). Keeping the new check inside
  `authorize/2` keeps that true, and member 5's probe MP2 proves it.
- **Guests:** the external chat allowlist (`tool_surface.ex:114`, `@external_chat_tools`) becomes a
  test oracle. A guest-owned runtime yields exactly those six tools from the permissions alone,
  and no name list is kept as a second decision point.
- Member 2's per-bundle registry entries are a transitional vocabulary for its shadow
  `Scope.for_runtime/1` and its equivalence test. Member 5's per-tool map supersedes them.
  `bundle_permissions/1` is the static union over the tools a bundle can list.

**A per-runtime tool profile is a preference, never a grant.** `access_runtime_profiles.tool_profile`
is an ordered module list that limits catalogue size. A tool is listed only if the profile names
its module AND the capped scope holds its permission. The experiment surface
`agents.tool_profile` can only remove modules from the stored profile, and it keeps the stored
order.

**Day-one translation: every existing runtime's tool list stays byte-identical, order included.**
- `ToolSurface.list_tools/1` (`tool_surface.ex:217`) walks `allowed_bundles` in row order.
- Member 5 measured 34 of 37 fabrikam lists and 1 of 1 ellis list out of catalogue order, and found
  same-set rows that hash differently.
- So the migration copies `allowed_bundles` verbatim into `tool_profile`, and sets
  `restricted_permissions` to the union of `bundle_permissions/1` over that array.
- It asserts inside `up` that no copy differs, and raises if one does.
- `allowed_bundles` is dropped in a second migration that re-verifies the copy before dropping
  (member 5's stage 4).

The named exceptions, all member 5's:
1. Control Center management narrows to owner-or-`agents.manage_all`.
2. A **new** runtime inherits its owner.
3. A runtime whose owner holds no membership gets no tools. Prod has none.
4. The "not in allowed bundles" refusal text is reworded.

**The `jack-mobile-claude` runtime is settled by Rowan's ruling,** recorded on member 5 on
2026-10-14: *"jack can be an admin for now. its fine."* That runtime lists the whole catalogue and
is owned by a plain root-org member. Its `prompt_template_update` maps to `prompts.manage`, which
no built-in role carries. Experiment human writes are install-level, but its experiment tools map
to `experiments.propose`, which `member` carries.
- **Being an org admin is enough here, and the reason is specific:** a root-org admin IS the root
  admin (`root_admin?/1`, `tenancy.ex:1075`), so the root-admin rule gives that owner
  `prompts.manage`.
- A *sub-org* admin would not hold it.
- None of that runtime's tools maps to `install.admin`.
- The promotion is a human action that must happen before deploy (member 5's ruling block).

## Delegation and audit

**`access.manage` on a scope; nobody can grant beyond what they hold** (member 6,
`Platform.Access.Delegation`).
- Every change needs `can?(actor, "access.manage", R)`. That inherits downward, so a manager of
  project P manages the execution spaces and canvases below P. A space manager cannot change a
  grant on its project.
- Granting permission p on R additionally needs `can?(actor, p, R)`. That covers granting
  `access.manage` itself.
- A deny needs only `access.manage`, because it narrows.
- **Revoking a deny widens access, so it is checked like an allow.**
- The grant's `org_id` must equal R's owning org.
- An undo is authorized as its inverse change.
- The built-in `admin` row carries `access.manage => "membership_org"`. `member` and `guest` never
  carry it.

**Root admin is an audited bypass.** A root admin is authorized for every delegation change.
The ledger row records `bypass: "root_admin"`.

**The last admin can't be removed.** `Delegation.ensure_manager_remains/2` runs inside the
change's transaction. Two rules govern the count:
- if a resource or org had one or more `access.manage` holders before the change and none after,
  the change rolls back;
- root-admin bypass does not count as a manager, because break-glass is not administration.

The human demotion path through `SignInAdmin` is guarded too. **The raw `Tenancy.revoke_admin/2`
(`tenancy.ex:1839`) is deliberately not guarded.** It is the operator path, and existing tests
demote a sole admin through it. Member 9's panel must not call it.

**Audit, with undo** (member 6). `access_grant_changes` is the ledger. Each row records:
- `actor_type` (`user`, `agent` or `system`) and `actor_id`;
- `via_agent_id`, the `agent_runtimes.id` that applied the change on a human's behalf;
- `bypass`;
- `action`: `grant`, `deny`, `revoke`, `undo` or `system_repoint`;
- `before` and `after`, which are full-row snapshots taken in the same transaction as the change;
- `tuple_keys`;
- `undoes_change_id`.

`Changes.commit/4` is the **one writer** to `access_grants`. That includes member 3's node-merge
re-point, recorded as `system_repoint`. `Changes.undo/3` restores rows verbatim, original ids
included. It is refused when a later change shares a tuple (`superseded`) or when the change was
already undone. Undoing an undo is a redo. `audit_events` gets a mirror event
(`[:platform, :access, :grant_changed]`); it is never the undo source, because
`Audit.record/1` runs after the fact from telemetry.

**View-as** (member 6):
- `ViewAs.compute/2` builds the target's scope with the real builders: `for_user/1`,
  `for_runtime/1` and `for_role/2`.
- It calls the real listing and rail functions.
- It intersects the result with the viewer's own reach.
- It needs `access.manage` over the target's org, or root admin.

Member 9 later absorbs its page into the Access panel as a shared component.

**Live apply** (member 6). After a change commits, never inside the transaction,
`Access.Live.broadcast_changed/1` sends `{:access_changed, change_id}` on `"access:user:" <> id`.
The recipients are each affected user: a user principal, or every member holding the role for a
role principal. An agent principal broadcasts nothing, because MCP builds `for_runtime/1` per
request. `ShellLive` rebuilds `:access_scope` and calls the view's `on_access_changed/1`.
`@external_scope` is never reassigned.

### Ledger coverage

The ledger covers `access_grants` only. Member 8's rows are written outside `Changes.commit/4`:
`access_role_assignments` (including IdP syncs), `access_space_restrictions` and
`access_idp_group_roles`.
- They are not undoable from the ledger, and member 9's change cards do not cover them.
- A role restriction acts as a deny on every non-holder, so leaving it unaudited is a known gap,
  not a design choice (Open question 5).
- Restrictions are read at decision time, so they apply on the next request or navigation
  without live apply.
- The cascade that deletes a custom role's `access_grants` rows also bypasses the ledger.

Member 9's plan adds this paragraph's substance. It is written here so that member 9 finds it
already present.

## Root-admin carve-outs

**Install-level settings stay root-admin and are never grantable as org permissions.** They are
gated by `install.admin` through `ModuleGate` and re-checked in each context with
`Access.authorize_install/1`, which replaces each context's own `Tenancy.root_admin?/1` check.
Return shapes stay `{:error, :unauthorized}`. With guest dominance, the external root admin is now
also refused inside the context, not only by the HTTP plug. HTTP outcomes do not change.

Every route in the `:admin` live_session (`router.ex:933-983`) and the `:admin_sign_in` session
(`router.ex:1007-1015`) is classified below:

| Route (router.ex line) | Class | Permission | Context re-check today → v2 |
|---|---|---|---|
| `/admin` (`:940`) | install-level | `install.admin` | landing only. Moved tiles leave it. |
| `/admin/recovery` (`:941`) | install-level | `install.admin` | |
| `/admin/external-logins` (`:945`) | install-level | `install.admin` | |
| `/admin/users` (`:946`) | install-level | `install.admin` | |
| `/admin/orgs` (`:954`) | install-level | `install.admin` | `Lifecycle.with_root_admin_authz/2` (`tenancy/lifecycle.ex:1173`) → `authorize_install/1` |
| `/admin/branding` (`:961`) | install-level | `install.admin` | `Branding.with_root_admin_authz/2` (`branding.ex:362`) → `authorize_install/1` |
| `/admin/prototypes` (`:965`) | install-level | `install.admin` | `Prototypes.Settings.update/2` (`prototypes/settings.ex:64`) → `authorize_install/1` |
| `/admin/vault`, `/admin/vault/:slug` (`:969-970`) | install-level | `install.admin` | `Platform.Vault.Shared` (`vault/shared.ex:365`) → `authorize_install/1` |
| `/admin/federation` (`:973`) | install-level | `install.admin` | |
| `/admin/sign-in-users` (`:1014`) | install-level (the IdP side of OIDC) | `install.admin` | `SignInAdmin` (`sign_in_admin.ex:433`) → `authorize_install/1`. Still a 404 to everyone while `POCKET_ID_ADMIN_ENABLED` is off; that is a module-disabled 404, not a denial. |
| `/admin/prompts`, `/admin/prompts/:slug` (`:971-972`) | **module** (Prompts) | `prompts.manage` | `PromptTemplates.update_template/2` (`orchestration/prompt_templates.ex:117`) takes no actor today. Member 4 adds an actor-checked `update_template/3`. |
| `/admin/pipeline` (`:981`) | **module** (Tasks) | `tasks.manage` at `:all` | `pipeline_live.ex:78` re-checks `:root_admin?`. That check is replaced by Access, and member 4 moves the view under `/tasks/...`. |

- **OIDC itself has no settings UI.** It is env config (`OIDC_EXTERNAL_GROUP` at
  `config/runtime.exs:180`), so nothing grants it.
- **Experiments** live at `/control/experiments` (`router.ex:864-865`):
  - reads are member-visible (`experiments.read`);
  - **every human write is install-level**. `ExperimentsLive.admin_only/2`
    (`experiments_live.ex:597`) is the only gate today. Member 4 adds `authorize_install/1` to each
    write in `Platform.Experiments`;
  - the agent path (an agent `start` becomes `:pending_human_approval`) is unchanged and needs
    `experiments.propose`.
- **Prompts move to a module permission, not install-level.** Member 5 requires that no tool
  permission be install-level, and `prompt_template_update` is an MCP tool in the `plan` bundle
  (`tool_surface.ex:3892`). `prompts.manage` is held with no grants only through the root-admin
  rule, and it can be granted. The route can stay under `/admin` while `ModuleGate` maps it to
  `prompts.manage`; moving it is optional.
- **Pipeline moves into Tasks.** Its data is install-wide, so it requires
  `permitted_ids(scope, "tasks.manage") == :all`, and a project-scoped grantee gets the access page.
- **Vault stays install-level, and vault grants stay a separate system on purpose.**
  - `vault_access_grants` (`vault/access_grant.ex:17`) holds explicit per-credential, per-agent
    grants, checked by `check_explicit_grant` (`vault.ex:820-890`).
  - Secret material has its own grant semantics and its own audit trail, so it is not folded into
    `access_grants`.
  - The MCP tools `vault_fetch` and `vault_list` (the `federation` bundle) need `vault.use` to be
    listed, and the vault's own grant still decides which credential they reach.
- **Federation stays install-level.** `/admin/federation` is install-wide runtime administration.
  Per-agent federation (connecting your own agent) is `agents.manage_own` in Control Center.
- **A module admin never reaches an install-level route.** A member-4 grantee of `tasks.manage` or
  `prompts.manage`, and a sub-org admin, get the access page on every install-level route.
  Member 3's `Access.Grants` refuses any grant naming `install.admin`.

## IdP groups → roles

**A list of group → role mappings generalizes the single `OIDC_EXTERNAL_GROUP`** (member 8,
`Platform.Access.IdpGroupRoles`, table `access_idp_group_roles`). The input is the `groups` claim:
- `@default_scope` includes `groups` (`oidc.ex:2`);
- `claim_groups/1` (`oidc.ex:92`) returns the list;
- `normalize_oidc_user/1` carries it on every login.

The rules:
- **`sxi-external` stays mapped to guest by default.** `mappings/0` is the implicit
  `%{group_value: OIDC.external_group(), role_key: "guest", org_id: nil}` plus every DB row, so
  the env var keeps working with no row. The env var is not renamed or removed.
- **Guest mappings mark the login external.** A login whose groups match any guest mapping takes
  today's external admission path. With a staged grant it ends `:full` with an `external: true`
  membership; without one it ends `:holding / :awaiting_grant`. Guest dominance then makes the
  user a guest.
- **Non-guest mappings target custom roles only.** Mapping a group to built-in `admin` or `member`
  is refused (`:builtin_not_mappable`). The base role comes from `derive_role_from_email/1` plus
  `roles_locked_at`, and an IdP path to admin would be an unreviewed escalation.
- **Every matching mapping applies.** A user in two mapped groups gets both roles.
- **Sync happens only when a login is `:full`, internal, and its claims actually carry `groups`.**
  `sync` inserts and deletes `source: "idp"` assignments and never touches `manual` ones.
  - A login with no `groups` claim (dev login, app handoff) writes nothing.
  - A present but empty list revokes idp-sourced roles.
  - An external login's other mappings are recorded in telemetry only.
- `org_group_claims` (group → org for the holding suggestion, `tenancy.ex:923-927`) is a different
  mapping and stays as it is.

## UX

**The admin's agent normally drives access changes; the UI is for emergencies** (member 9).

**Change cards.** The new `access` core bundle carries four tools. It is appended last in
`@bundles` (`tool_surface.ex:86`) and never added to an existing bundle, so translated tool lists
stay byte-identical. Every tool needs `access.manage`.
- `access_explain`: why X can or cannot see Y, computed through `ViewAs.compute/2` and `can?/3`.
- `access_propose`: dry-runs `Changes.commit/4`, computes the impact diff, and posts a
  server-built canvas card into a space.
- `access_apply`: **never commits.** It returns the proposal's status, for example
  `awaiting_human_approval`.
- `access_undo`: creates an undo proposal and its card.

**The change applies only when a human clicks Apply.**
- The click is handled in the human's LiveView (`canvas_hooks.ex`), with a Scope rebuilt from the
  DB at click time.
- The proposal is looked up by the clicked canvas id, never by an id carried in the event.
- A card digest catches an agent's later `canvas.patch` of the card.
- The impact is recomputed at click time, and the card goes stale if it changed.
- A single-use compare-and-swap blocks a double apply.
- A DB CHECK requires a `users` FK approver.

The resulting ledger row reads "as the approving human": `actor_id` is the human, and
`via_agent_id` is the runtime. Removals come first, and every person and agent who loses access is
named; the list is never collapsed to "and N others". The copy uses "lose access", "gain access"
and "Apply".

**The break-glass Access panel** is at `/access` and `/access/:type/:id`, mapped by `ModuleGate`
to `access.manage`. It shows:
- a banner: "Break-glass view. Normally your agent does this, and changes made here are logged the
  same way.";
- effective access per person or agent, with each line's source (role, grant, inherited, deny,
  capped, restricted);
- a view-as toggle;
- the change log with undo;
- "Reset selected person to role defaults". Reset revokes every per-person grant and deny and
  keeps the role.

**Difference from the prototype, recorded:** member 9 opens reset as the same inline change card,
behind Apply, not as a one-click action. The task requires removal lists to name everyone, and
the prototype's one-click reset would skip that.

## Denials explain why and who can grant

**One denial shape for UI, MCP envelopes and deep links:**
`%Platform.Access.Denial{permission, resource, rule, granters}`.
- **`rule`** is one of:
  - `deny`, `restricted` or `not_granted`, from § Precedence;
  - `capped_at_owner`;
  - `install_level`;
  - `beyond_held` and `last_admin`, from § Delegation and audit.
- **`granters`** are the named principals who hold `access.manage` on the resource (or root admin
  for `install_level`). They are computed through `Delegation`, so the list exists only once
  member 6 lands. Before then the field is empty, and the copy says "ask an admin".

**Existence is never confirmed for a resource the actor cannot see.** Missing and denied
resources must not be told apart. The rules per surface:
- **UI deep links.** A denied module route renders the standalone access page: status 403, the
  text "You don't have access, ask an admin", no rail and no shell. A denied resource and a
  missing one inside a module render byte-identical bodies (member 4).
- **MCP.** A denied resource returns the same envelope a missing one returns (members 3 and 7). A
  denied *tool* returns `-32001` with text naming the permission and the cap (member 5).
- **Where the resource's existence is already visible to the actor, the full shape is shown:**
  - a module the rail hides;
  - a restricted channel, which stays listed as "Restricted, ask an admin" (member 8);
  - a change-card refusal (member 9).

**Difference from the brief, recorded:** the brief says "no 404 and no blank page". That holds for
every UI deep link, which gets the access page and never a 404. MCP and in-module resource lookups
answer exactly like "not found", because three member plans need that to avoid an existence
oracle.

## Design rule: not Byzantine

**Out of the box nothing changes, and every advanced feature is opt-in.** With no grants, no custom
roles, no restrictions and no IdP rows, every actor sees exactly what it sees today. Every member
proves this with member 2's equivalence test, unmodified.

Rowan, in the settlement: *"This can't be too Byzantine. It should be powerful and help enforce,
but out of the box tremendously restricting agent capability will confuse users."*

Rowan, in the settlement: *"this permissions system will ALMOST always be driven by the admins
agent. We can have a UI, but it's almost for emergencies."*

What follows from that:
- An agent inherits its owner unless someone restricts it.
- The tool profile never grants.
- Denies, restrictions and custom roles exist only when someone adds them.
- The Access panel is labelled break-glass.

## Per-member build map

One row per downstream stack member. Each row names the sections it implements and its own
falsifier.

| Pos | Member | Title | Implements | Member's falsifier, and how this ADR answers it |
|---|---|---|---|---|
| 2 | `01a1386d-cb5c` | Permission registry, Scope and built-in roles mapped from today's model, with no visible change | § Permission model, § Built-in roles, and the stage-1 mapping table | "If an equivalence test cannot be written because today's access isn't derivable from role + external + participants + root admin, stop." Answered: the mapping table derives every actor class from those four inputs plus root-org membership. The two non-data rules (root-org widening, root admin) are named in § Built-in roles. |
| 3 | `01a1386d-e528` | Resource-scoped grants with inheritance and deny: projects, spaces, org-memory subtrees | § Levels and inheritance, § Precedence, § Memory grants | "If org-memory pages have no stable node id, stop and settle the anchoring." Answered: settled in § Memory grants (node entity, path history, lazy nodes, rename moves the node, delete keeps it, overwrite merges fail-closed). Note: this ADR adds the direct space-to-canvas edge to member 3's edge list. |
| 4 | `01a1386d-fb6e` | Module gating: rail, live_session and context checks; admin views return to their modules | The rail rule in § Permission model, § Root-admin carve-outs, § Denials explain why and who can grant | "If the shell rail is not built from a single filterable list, stop." Not an ADR question; member 4 measured that it is (`icon_rail.ex:671`). Its classification falsifier ("every `:admin` route classified") is answered by the route table in § Root-admin carve-outs. Member 4 closes the guest live-redirect path into the unscoped Tasks board (`ModuleGate`) and re-checks Tasks writes. It does **not** narrow an internal user's default `tasks.read :all`, which is today's behaviour by design. |
| 5 | `01a1386e-1710` | Agents on the rail: users own their agents, agent scope capped at its owner, MCP tools gated by permission instead of bundles | § Agents | "If `owner_user_id` is not reliably set, backfill first." Measured NOT NULL with 0 dangling on both installs. Its owner-cap falsifier for `jack-mobile-claude` is settled by Rowan's ruling (§ Agents); none of that runtime's tools is `install.admin`. |
| 6 | `01a1386e-30bd` | Delegation, view-as, audit log and live apply for access changes | § Delegation and audit, including § Ledger coverage | "If permissions are not cached per socket, decide the caching first." Answered: the cache is member 2's `:access_scope` assign carrying member 3's grant snapshot, rebuilt over PubSub after commit. Member 6's "not capped at owner (pos 5)" view-as label goes stale once member 5's cap lands (member 9 fixes it). |
| 7 | `01a1386e-45a5` | Close the bypass surfaces: files-service, task-router dispatch, notifications, search and mentions | The stage-1 "Bypass surfaces" table | "If files-service already authorizes against core's Scope, drop that part." Answered: files-service has no user read surface (`GET /health` and token-gated `POST /extract` only, at `42b43055e1b9`), so enforcement is on core's controllers and member 7 drops the files-service part. **Member 7 runs its checks in conjunction with each surface's existing check, rather than replacing it** (the stage-1 table's files row says "replaces"; member 7's choice stands). Because a grant-less scope short-circuits to `:ok`, a grant-less install keeps today's two gaps: `CanvasHooks.find/2` still resolves any canvas id for an internal user, and FilesLive `load_project/2` still has no check. Member 7 closes them only for resources under a grant or deny, and records the FilesLive gap as pre-existing. |
| 8 | `01a1386e-59d1` | Custom roles, role-restricted channels and mapping IdP groups to roles | § Built-in roles (custom roles), § Precedence step 5, § IdP groups → roles | "If OIDC claims no longer carry `groups`, stop." Measured on main: they do (`oidc.ex:2`, `:92`). The base role stays derived (member 8's choice, which differs from member 2's forecast). |
| 9 | `01a1386e-72e1` | Agent-first access UX: change-card MCP tools and the break-glass Access panel | § UX, § Denials explain why and who can grant | "If the delegation/audit member did not ship an undo-able change log, stop." Answered: member 6's `Changes.commit/4` / `undo/3` ledger. Member 9 also maps `AccessViewAsLive` in `ModuleGate`, which member 6 left unmapped. |

## Open questions

1. **Memory node anchoring: resolved, not open.** Recorded in § Memory grants as member 3's
   settled design. It does not block member 3.
2. **The ownerless built-in agent cap: decided** in § Agents (the root org's built-in `member`
   set). What remains open is who builds it: no member constructs a Scope for an agent without a
   runtime, because `for_runtime/1` takes an `AgentRuntime`. Until a member does, ownerless
   agents stay outside Access, exactly as today: they use `ToolRunner` and never reach
   `ToolAuthorization`.
3. **`Wiki.Routing.gate_write/3` has no builder.** § Memory grants decides the replacement (pin OR
   capped node grant), but member 3's stage 4 explicitly keeps the Historian gate and no other
   member rewrites it. Until a follow-up task does, agent page writes stay Historian-only, which
   is consistent with no behaviour change.
4. **`Chat.SpaceAccess.authorize_writer/2` has no builder.** `chat.write` on a space is decided by
   participation there, and no member routes it through Access. A deny of `chat.write` therefore
   does not yet stop a participant from posting.
5. **Conflicts between member plans, which whichever member lands second resolves:**
   - Member 7 and member 8: the grant-less short-circuit in `Access.check/3` skips role
     restrictions. Decided in § Precedence (also check for a restriction row); the code is
     unbuilt.
   - Member 8: deleting the last custom role that restricts a space cascades the restriction away,
     which **fails open**. Member 8's plan calls that intended and pins it with a test; the
     architect asked for a fail-closed refusal. This needs Rowan's choice. Until he makes it, the
     member-8 behaviour is what ships.
   - Member 8's assignment, restriction and IdP rows are outside the ledger (§ Ledger coverage).
   - `chat/attachments/tool_handlers.ex:392` keeps a second `assert_agent_in_space` beside
     `tool_surface.ex:15431`, and no member folds the two together.
6. **files-service premise: resolved.** Measured at `Startup-Suite/files-service` `42b43055e1b9`:
   `app/main.py` declares only `GET /health` and `POST /extract`, the latter stateless and behind
   the shared `FILES_SERVICE_TOKEN` bearer (`app/auth.py:27`). It has no storage and no
   user-reachable read. Enforcement belongs on core's byte-serving controllers (the stage-1
   files-service and file-blob rows). Member 7 drops the files-service part. If files-service
   ever gains a read route, that route needs a row in the bypass table first.
7. **The "guest" term collision: resolved.** The built-in role is **guest**: a signed-in user with
   a user row. The unauthenticated `:guest_meeting` actor (`router.ex:760`, bearer slug+token
   checked by `Meetings.resolve_guest_invite/2`) is a **meeting invitee**. It holds no role and no
   `%Scope{}` beyond `Scope.for_meeting_invitee/1`, which is empty. Code that touches the
   `:guest_meeting` live_session, the `:guest` layout or `resolve_guest_invite/2` never reads or
   writes the `guest` role. The code identifiers that already say "guest" for meeting invitees
   are not renamed in this stack.
8. **The live security gap in Control Center is not this ADR's to fix.** `control_center/runtime_events.ex:58-83`
   lets any internal user regenerate another user's agent token and shows it to them. Member 5
   closes it in its stage 3; the architect recommended a hotfix on main ahead of the stack.

## Consequences

- **Positive:**
  - One decision point and one ledger.
  - Agents can no longer act beyond their owner.
  - Bundles stop being authorization, while every existing tool list stays byte-identical.
  - Memory grants survive renames.
  - Guests become an inspectable, explainable role instead of a flag that silently subtracts
    access.
- **Negative:**
  - Eight new `access_*` tables, plus two `org_memory_*` tables.
  - A Scope build per request and per socket.
  - The rollup ships many migrations in one deploy, so member 5's column drop re-verifies the
    translation inside the database.
- **Deliberate narrowings, all named in a member plan:**
  - Control Center management becomes owner-or-`agents.manage_all`;
  - creating an ownerless agent becomes `agents.manage_all` only;
  - the external root admin is refused inside install-level contexts as well as by the plug;
  - a zero-membership owner's runtime gets no tools.
- **Deliberate widening:** a new runtime inherits its owner by default, including page writes its
  owner can make (§ Memory grants).
- **Kept as they are today, on purpose:**
  - the unscoped Tasks board for internal users;
  - `CanvasHooks.find/2` and FilesLive `load_project/2` on a grant-less install;
  - participation-based chat writes;
  - Historian-only agent page writes until Open question 3 has a builder.
