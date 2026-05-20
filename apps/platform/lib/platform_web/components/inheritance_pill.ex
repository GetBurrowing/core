defmodule PlatformWeb.Components.InheritancePill do
  @moduledoc """
  Inheritance-provenance pill — labels a value with where it came from in
  the org hierarchy: inherited from a parent, defined here, or overridden.

  Part of the Suite scope-provenance system (sibling to `ScopePill` and
  `IconRail`). Lives on the `ui-foundation-primitives` stack alongside
  other low-level chrome.

  ## Purpose

  Many Suite surfaces show values (skills, context, memory, prompts) that
  may be defined at the root org level and inherited by tenant orgs, or
  defined locally on a tenant. This pill is the affordance that tells the
  user which case they're looking at — and (for Fabrikam admins) the click
  target to open the override dialog.

  Reads state from `Platform.Tenancy.effective_value/4` (the inheritance
  resolver). Caller passes a `:lookup_fn` matching its record type.

  ## Three visual states

    * `Inherited from Fabrikam` — muted text, no accent (`:inherited`).
    * `Defined here` — accent color matching the sub-org scope
      (`:defined_here`).
    * `Overridden` — accent color + bold + subtle "shadowed parent"
      indicator (`:overridden`).

  ## Click-target semantics

  The pill is a clickable button that opens the override dialog (Stage 3
  — not yet shipped) when ALL of the following are true:

    * the resolved state is `:inherited`
    * the caller's `@fabrikam_admin?` assign is `true`

  Non-admin click: no-op + tooltip `"Only Fabrikam admins can override"`.
  Non-inherited states render as a non-interactive `<span>` (there's
  nothing to override on a value that's already local).

  The `@fabrikam_admin?` assign is set by `PlatformWeb.LiveAuth.on_mount(:default)`
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
        fabrikam_admin?={@fabrikam_admin?}
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

  attr(:scope, :atom,
    required: true,
    values: [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon],
    doc:
      "The sub-org scope slug. Drives the accent color in the `:defined_here` and `:overridden` states (no accent for `:inherited`)."
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

  attr(:fabrikam_admin?, :boolean,
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
      |> assign(:override_click_target?, state == :inherited and assigns.fabrikam_admin?)
      |> assign(:non_admin_inherited?, state == :inherited and not assigns.fabrikam_admin?)

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
          title="Only Fabrikam admins can override"
          data-tooltip="Only Fabrikam admins can override"
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
  # shape onto the 3-state UI vocabulary plus the optional `parent_scope`
  # slug used for `aria-label` text.
  defp resolve_state(%{org: org, record_key: key, default: default, lookup_fn: lookup_fn}) do
    case Tenancy.effective_value(org, key, default, lookup_fn: lookup_fn) do
      {:defined_here, _value} ->
        {:defined_here, nil}

      {:overridden, _value, _parent_value} ->
        # The parent value comes from the nearest defining ancestor; for
        # the two-tier Fabrikam/tenant hierarchy that's always Fabrikam.
        {:overridden, :fabrikam}

      {:inherited, source_org, _value} ->
        {:inherited, scope_from_org(source_org)}
    end
  end

  # Convert an `Org` struct to its scope-slug atom. The DB slugs match
  # the scope atoms 1:1 (see `priv/repo/migrations/20260519143620_seed_root_orgs.exs`).
  # Falls back to `:fabrikam` (the inheritance source for tenants) for any
  # unknown shape so the pill stays renderable on partially-loaded data.
  defp scope_from_org(%{slug: slug}) when is_binary(slug) do
    case slug do
      "fabrikam" -> :fabrikam
      "soylent" -> :soylent
      "wayne_tech" -> :wayne_tech
      "sxi" -> :sxi
      "paragon" -> :paragon
      _ -> :fabrikam
    end
  end

  defp scope_from_org(_), do: :fabrikam

  # ── Labels ────────────────────────────────────────────────────────────

  defp label_for(:inherited, parent_scope),
    do: "Inherited from #{Tenancy.scope_label(parent_scope)}"

  defp label_for(:defined_here, _), do: "Defined here"
  defp label_for(:overridden, _), do: "Overridden"

  defp aria_label_for(:inherited, parent_scope),
    do: "Inherited from #{Tenancy.scope_label(parent_scope)}"

  defp aria_label_for(:defined_here, _), do: "Defined here"

  defp aria_label_for(:overridden, parent_scope),
    do: "Overridden from #{Tenancy.scope_label(parent_scope)}"

  # ── Class mapping ─────────────────────────────────────────────────────

  defp state_class(:inherited), do: "inheritance-pill--inherited"
  defp state_class(:defined_here), do: "inheritance-pill--defined"
  defp state_class(:overridden), do: "inheritance-pill--overridden"

  # Inherited state has no accent (muted base-content); the other two
  # carry the sub-org scope's text color via `Tenancy.scope_color/1`.
  defp accent_class(:inherited, _scope), do: nil
  defp accent_class(_state, scope), do: Tenancy.scope_color(scope)
end
