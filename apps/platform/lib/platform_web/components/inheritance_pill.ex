defmodule PlatformWeb.Components.InheritancePill do
  @moduledoc """
  Inheritance-provenance pill — labels a value with where it came from in
  the org hierarchy: inherited from a parent, defined here, or overridden.

  Part of the Burrow scope-provenance system (sibling to `ScopePill` and
  `IconRail`). Lives on the `ui-foundation-primitives` stack alongside
  other low-level chrome.

  ## Purpose

  Many Burrow surfaces show values (skills, context, memory, prompts) that
  may be defined at the root org level and inherited by tenant orgs, or
  defined locally on a tenant. This pill is the affordance that tells the
  user which case they're looking at — and (for root-org admins) the click
  target to open the override dialog.

  Reads state from `Platform.Tenancy.effective_value/4` (the inheritance
  resolver). Caller passes a `:lookup_fn` matching its record type.

  ## Three visual states

    * `Inherited from <root org name>` — muted text, no accent (`:inherited`).
    * `Defined here` — accent color matching the sub-org scope
      (`:defined_here`).
    * `Overridden` — accent color + bold + subtle "shadowed parent"
      indicator (`:overridden`).

  ## Click-target semantics

  The pill is a clickable button that opens the override dialog (Stage 3
  — not yet shipped) when ALL of the following are true:

    * the resolved state is `:inherited`
    * the caller's `@root_admin?` assign is `true`

  Non-admin click: no-op + tooltip `"Only root-org admins can override"`.
  Non-inherited states render as a non-interactive `<span>` (there's
  nothing to override on a value that's already local).

  The `@root_admin?` assign is set by `PlatformWeb.LiveAuth.on_mount(:default)`
  (already shipped — see PR #396 / commit 2cde6ec).

  ## Accessibility

  Each state has a distinct `aria-label`:

    * `:inherited` — "Inherited from {parent-scope-name}"
    * `:defined_here` — "Defined here"
    * `:overridden` — "Overridden from {parent-scope-name}"

  ## Examples

      <.inheritance_pill
        org={@current_org}
        scope={:soylent}
        record_key={:my_skill}
        default={nil}
        lookup_fn={&Skills.lookup_for_org/2}
        root_admin?={@root_admin?}
      />

  """
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Tenancy

  @type state :: :inherited | :defined_here | :overridden

  attr(:org, :any,
    required: true,
    doc:
      "The `%Platform.Tenancy.Org{}` whose perspective we are rendering. Passed to `effective_value/4`."
  )

  attr(:scope, :any,
    required: true,
    doc:
      "The sub-org scope: one of `ScopePill.scopes/0`, or an org slug string (the root org has no compiled atom). Drives the accent color in the `:defined_here` and `:overridden` states (no accent for `:inherited`)."
  )

  attr(:record_key, :any,
    required: true,
    doc: "The lookup key passed through to `lookup_fn` (e.g. a skill id, context key)."
  )

  attr(:default, :any,
    default: nil,
    doc:
      "Default value the resolver substitutes when neither this org nor any ancestor defines `record_key`. Mirrors the `default` arg to `Tenancy.effective_value/4`."
  )

  attr(:lookup_fn, :any,
    required: true,
    doc:
      "2-arity function `(org, key) -> {:ok, value} | :error` over the caller's storage. Passed straight to `Tenancy.effective_value/4`."
  )

  attr(:root_admin?, :boolean,
    default: false,
    doc:
      "When true and the state is `:inherited`, renders the override click-target. When false, the click is a no-op showing a permission tooltip."
  )

  attr(:on_override, :string,
    default: "open_override_dialog",
    doc:
      "phx-click event name fired when an admin clicks an inherited pill. Stage 3 wires the parent LV to handle this; v2 ships without."
  )

  def inheritance_pill(assigns) do
    {state, parent_scope} = resolve_state(assigns)

    assigns =
      assigns
      |> assign(:state, state)
      |> assign(:parent_scope, parent_scope)
      |> assign(:label, label_for(state, parent_scope))
      |> assign(:aria_label, aria_label_for(state, parent_scope))
      |> assign(:override_click_target?, state == :inherited and assigns.root_admin?)
      |> assign(:non_admin_inherited?, state == :inherited and not assigns.root_admin?)

    ~H"""
    <%= cond do %>
      <% @override_click_target? -> %>
        <button
          type="button"
          phx-click={@on_override}
          phx-value-record-key={to_string(@record_key)}
          class={[
            "inheritance-pill",
            state_class(@state),
            accent_class(@state, @scope),
            "focus-visible-ring cursor-pointer"
          ]}
          aria-label={@aria_label}
        >
          {pill_inner(assigns)}
        </button>
      <% @non_admin_inherited? -> %>
        <span
          class={[
            "inheritance-pill",
            state_class(@state),
            accent_class(@state, @scope),
            "cursor-not-allowed"
          ]}
          aria-label={@aria_label}
          title="Only root-org admins can override"
          data-tooltip="Only root-org admins can override"
        >
          {pill_inner(assigns)}
        </span>
      <% true -> %>
        <span
          class={[
            "inheritance-pill",
            state_class(@state),
            accent_class(@state, @scope)
          ]}
          aria-label={@aria_label}
        >
          {pill_inner(assigns)}
        </span>
    <% end %>
    """
  end

  defp pill_inner(assigns) do
    ~H"""
    <%= if @state == :overridden do %>
      <.icon name="hero-arrow-uturn-left" class="size-3" />
    <% end %>
    <span class="inheritance-pill-label">{@label}</span>
    """
  end

  # ── State resolution ──────────────────────────────────────────────────

  # Calls `Tenancy.effective_value/4` and maps its tagged-tuple return
  # shape onto the 3-state UI vocabulary plus the optional `parent_scope`,
  # the source org's NAME as stored on its row, used for the label and
  # `aria-label` text. No org name is compiled in: the root org is whatever
  # row the install seeded.
  defp resolve_state(%{org: org, record_key: key, default: default, lookup_fn: lookup_fn}) do
    case Tenancy.effective_value(org, key, default, lookup_fn: lookup_fn) do
      {:defined_here, _value} ->
        {:defined_here, nil}

      {:overridden, _value, _parent_value} ->
        # `effective_value/4` names the defining ancestor only for the
        # inherited case. In the two-tier root/tenant hierarchy the parent
        # of a tenant is the root org, so the label reads the root org's
        # own row (`Tenancy.get_root_org/0`, structural: parent_org_id IS
        # NULL), never a compiled name.
        {:overridden, org_name(Tenancy.get_root_org())}

      {:inherited, source_org, _value} ->
        {:inherited, org_name(source_org) || org_name(Tenancy.get_root_org())}
    end
  end

  # The org's display name as stored on its row. `nil` for anything that
  # is not a loaded org, so the caller can fall back to the root row and
  # the pill stays renderable on partially-loaded data.
  defp org_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp org_name(_), do: nil

  # ── Labels ────────────────────────────────────────────────────────────

  # `parent_name` is nil only when no root org row exists at all.
  defp label_for(:inherited, parent_name),
    do: "Inherited from #{parent_name || "the root org"}"

  defp label_for(:defined_here, _), do: "Defined here"
  defp label_for(:overridden, _), do: "Overridden"

  defp aria_label_for(:inherited, parent_name),
    do: "Inherited from #{parent_name || "the root org"}"

  defp aria_label_for(:defined_here, _), do: "Defined here"

  defp aria_label_for(:overridden, parent_name),
    do: "Overridden from #{parent_name || "the root org"}"

  # ── Class mapping ─────────────────────────────────────────────────────

  defp state_class(:inherited), do: "inheritance-pill--inherited"
  defp state_class(:defined_here), do: "inheritance-pill--defined"
  defp state_class(:overridden), do: "inheritance-pill--overridden"

  # Inherited state has no accent (muted base-content); the other two
  # carry the sub-org scope's text color via `Tenancy.scope_color/1`.
  defp accent_class(:inherited, _scope), do: nil
  defp accent_class(_state, scope), do: Tenancy.scope_color(scope)
end
