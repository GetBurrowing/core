# Onboard a tenant org

Ops procedure for adding a new client org (a "tenant" of the Fabrikam root org).

Introduced by task `019ffe9d`, which added `Tenancy.create_org/2`, the
`/admin/orgs` surface that calls it, and the `cyberdyne` scope ramp.

---

## READ THIS FIRST: the branch does not create any org

**`019ffe9d` ships a capability, a form and a colour ramp. It creates no org
rows.** Every org in the running system still comes from the seed migration
`20260519143620_seed_root_orgs.exs`, which seeds exactly five:
`fabrikam`, `soylent`, `wayne_tech`, `sxi`, `paragon`.

In particular: **Cyberdyne does not exist in production after this branch
deploys.** The diff registers `cyberdyne` as a scope — a label, a magenta
colour ramp, and an entry in every scope literal — so that *when* the org is
created it is visible. Registering the scope is not creating the org.

Somebody has to do step 1 below, by hand, once, after deploy. Reading the
merged diff and concluding "Cyberdyne is already there" is the specific
mistake this section exists to prevent.

Deliberately **not** done by migration: the fixtures in
`apps/platform/test/support/tenancy_fixtures.ex` rely on the seed migration
having run and do not seed on demand, and `tenancy_test.exs`,
`projects_test.exs` and `federation/tool_surface_org_filters_test.exs` all
assert the exact five-org seeded set. A sixth *seeded* org turns them red.
Runtime creation keeps them green. If you find yourself editing one of those
assertions, a seed has crept in — investigate rather than edit.

---

## Step 1 — create the org row (form, not migration)

Prereqs: you hold an `admin` `org_memberships` row **on the Fabrikam root org**.
`Tenancy.create_org/2` refuses anyone else, and `/admin/orgs` sits behind the
same `:ensure_admin` gate as `/admin/users`.

1. Go to `/admin/orgs`.
2. **New org**.
3. Fill **Name** (display name, e.g. `Cyberdyne`) and **Slug**.
4. **Create org**.

Slug rules (`Platform.Tenancy.Org`, `@slug_format`): `^[a-z][a-z0-9_-]*$` —
lowercase, starts with a letter, then letters, digits, hyphens or
underscores. Must be unique. A duplicate comes back as an inline error on the
field, not a crash.

Parentage is **derived, not chosen**: new orgs are created as tenants of the
single `parent_org_id IS NULL` row (Fabrikam). There is one root org, enforced by
the `orgs_single_root` partial unique index, so the form offers no parent
field and a crafted `org[parent_org_id]` cannot reparent anything.

Verify: the new row appears in the list as tier `Tenant`, and an
`platform.tenancy.org_created` audit event is recorded with your user as
actor.

---

## Step 2 — grant memberships

The form creates the org row and nothing else. A brand-new org has **zero
members**, and the Tasks scope rail is viewer-scoped
(`Tenancy.list_active_tenants_for_user/1`): a user sees an org's chip only if
they hold a membership in it. Fabrikam *admins* bypass the membership filter and
see every active org, which is why the chip can look fine to you and be
invisible to everyone else.

There is no UI for this yet — grant `org_memberships` rows directly.

---

## Step 3 — the part that is still a deploy

**Adding a client is now a form for the org row, but still a code change for
its scope-rail chip and colour.** Those live in hand-authored literals, not
in the database. The `/admin/orgs` list marks any org missing from
`Tasks.scope_keys/0` with a **"Not on rail"** badge for exactly this reason.

To put a new slug on the rail, append it to **all** of:

| File | What |
| --- | --- |
| `lib/platform/tasks.ex` | `@scope_keys` |
| `lib/platform/tenancy.ex` | `@scope_classes`, `@scope_labels` |
| `lib/platform_web/components/scope_pill.ex` | `@scopes`, `:propagated_to` attr values, `slug/1`, `scope_label/1` |
| `lib/platform_web/components/inheritance_pill.ex` | `:scope` attr values, `scope_from_org/1` |
| `lib/platform_web/live/chat_live.ex` | `section_scope_atom/1`, `section_dot_class/1`, `@sub_org_slug_to_bucket`, `sub_org_scope_atom/1`, `parse_scope/1`, `bucket_for_scope/1`, the recolor allowlist |
| `lib/platform_web/live/chat_live.html.heex` | the `~w()` swatch palette |
| `lib/platform_web/live/tasks_live.ex` | the empty-scope guard |
| `assets/css/app.css` | the colour ramp + the contrast-checked `-label` values (light **and** dark) |

`test/platform/scope_registry_consistency_test.exs` cross-checks these
sources, but its drift guard only covers `Tasks.scope_keys/0` vs
`ScopePill.scopes/0` — it cannot catch a slug registered in some literals and
not others. Check the chat surface and the inheritance pill, not just
`/tasks`.

### Colour ramp

Label text must clear **4.5:1 (WCAG 1.4.3 AA)** against the composited 12%
chip tint in **both** themes — light over `#FFFFFF`, dark over `#171b25`.
The full-saturation `text-<slug>` token is tuned for the dot and the active
fill, *not* for label text; that is what the separate `text-<slug>-label`
values are for. Measure, don't eyeball: whole-percent lightness steps can
overshoot the band (cyberdyne needed 55.5% / 67.5% at hue 340).

### Rail position

`Tenancy.tenant_priority/0` is a **curation list**, deliberately not extended
for every new org. `tenant_priority_index/1` returns a `9_999` sentinel for
unknown slugs, so an unlisted org sorts last, deterministically, with ties
broken slug-alphabetically. Add a slug to `tenant_priority/0` only when you
want it to jump the queue.

---

## Verification

After steps 1–3, for a user holding a membership in the new org:

- `Tenancy.tier/1` is `:tenant`, `parent_org_id` is the Fabrikam root id, and the
  org appears in `Tenancy.list_orgs/0` and `Tenancy.list_tenants/0`.
- Its chip appears on the `/tasks` scope rail, and its group appears in the
  Tasks project sidebar, in `list_orgs_in_priority_order/0` position.
- The chip renders in both themes: dot, 12% tint, border, hover, and the
  active full-fill.
- The label clears 4.5:1 in both themes.
- The chat surface renders it (section dot + recolor palette swatch).
- The five pre-existing scopes are unchanged — same hues, labels and rail
  order, Fabrikam still first.

**The failure mode to watch for is the org row existing while no chip appears
anywhere.** That is what a migration-only org used to produce, and it is why
step 3 is not optional.
