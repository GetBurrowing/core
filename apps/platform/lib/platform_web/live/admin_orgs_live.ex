defmodule PlatformWeb.AdminOrgsLive do
  # Declared ABOVE the moduledoc because the moduledoc interpolates the
  # proximity threshold, and a module attribute is only in scope after it
  # is set. Better that than a prose number that drifts from the guard.
  #
  # A pick within this many degrees of a hue already in use warns. Flat 20
  # degrees, and that is known to be the crude version: reachable chroma
  # runs from about 0.09 near hue 200 to about 0.28 near hue 295, so hues
  # in the low-chroma arc are LESS separable than the same 20 degrees
  # elsewhere and arguably want a wider window. Design canvas 01a0928d
  # raises it; nobody has ruled on it. Flat is honest about that, a
  # hand-tuned curve would not be.
  @proximity_degrees 20

  # The chroma a new org is stored and rendered at. The write path
  # deliberately does not widen to accept a chroma from the form: one
  # control, one decision. Read from `ScopeColor` rather than written out,
  # so the ring, the preview, the stored row and the rail cannot name
  # different numbers — which they did until task 01a09287 stage 5: this
  # module previewed 0.15, `form_attrs/1` never wrote `color_chroma` at all,
  # and the column's `default: 0.16` therefore decided what the rail
  # painted. The panel's own contract two hundred lines down says "the
  # numbers an operator reads off this panel are the numbers the server will
  # store", and it was false by 0.01 for every org created through it.
  @chroma Platform.Tenancy.ScopeColor.default_chroma()

  # Ring geometry, in the SVG's own 200x200 user units.
  @ring_center 100
  @ring_radius 74
  @ring_lightness 0.72

  @moduledoc """
  Orgs — the admin surface that makes `Platform.Tenancy.create_org/2`
  reachable by a human (task 019ffe9d stage 4).

  Stage 1 shipped the write; until this surface existed the only caller was
  a code path nobody could reach from a browser, so onboarding a client
  still meant shipping a migration. This is the form that removes the
  migration.

  ## Onboarding finishes here (task 01a09287 stage 4)

  It used to not. Until this stage the surface carried three pieces of
  apology copy, because an org created here got a rail chip but no scope
  COLOUR — the ramp was hand-authored CSS utilities, so the last step of
  standing up a tenant was still a deploy. Stage 3 moved those declarations
  to a render-time `<style>` block and this stage adds the control that
  feeds it, so the apology copy is gone rather than reworded. Leaving it
  would have turned working copy into a lie.

  ## Why a hue RING and not a hex field

  A hex input cannot express either constraint that governs this choice. It
  cannot tell an operator that the yellow they just typed will be invisible
  on white, and it cannot tell them that the blue is already Vandelay-Ind's.
  Both failures are silent and both are found by somebody else, later, on
  the scope rail. The ring shows the hues already taken as notches, warns
  within #{@proximity_degrees}° of one — and does NOT block, because two
  orgs may legitimately want adjacent colours.

  The preview below it shows TWO grounds, and that is not decoration. The
  two theme surfaces are 17.21:1 apart while AA on both would need
  4.5² = 20.25, so no single colour can clear AA as text on both themes;
  a one-ground preview lets an operator approve, on a dark screen, a colour
  nobody working in light can read. Every figure it prints is computed in
  `validate_org` by `Platform.Tenancy.ScopeColor`, never in JS, and every
  figure is printed WITH THE GROUND IT WAS MEASURED AGAINST — the same
  label reads 5.10 on bare white and 4.56 on its own 12% tint over white,
  so a bare number here is not interpretable.

  ## Authorization — defence in depth

    * The route lives in the `:admin` `live_session` in
      `PlatformWeb.Router`, whose `PlatformWeb.LiveAuth.on_mount(:ensure_admin, ...)`
      hook halt-redirects a non-admin mount.
    * AND the write itself re-checks: the acting user
      (`@current_user_record`, assigned by `LiveAuth.on_mount(:default, ...)`)
      is threaded into `Tenancy.create_org/2` as the actor, and
      `Lifecycle.with_root_admin_authz/2` answers `{:error, :unauthorized}`
      for anyone who is not a root-org admin. Neither check is load-bearing
      alone.

  Parentage is NOT a form field: `create_org/2` derives `:parent_org_id`
  from the single root org. The submit path passes only `name`, `slug` and
  `color_hue` through, so a crafted `org[parent_org_id]` on the wire cannot
  reparent anything or attempt a second root (which the `orgs_single_root`
  partial unique index would refuse anyway).
  """
  use PlatformWeb, :live_view

  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.ScopeColor

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Orgs")
      |> assign(:show_create_sheet, false)
      |> assign_blank_form()
      |> load_orgs()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_create_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_sheet, true)
     |> assign_blank_form()}
  end

  def handle_event("close_create_sheet", _params, socket) do
    {:noreply, assign(socket, :show_create_sheet, false)}
  end

  # Live validation renders the SAME changeset the write uses — no rule is
  # restated here. `Org.changeset/2` already carries required name+slug and
  # the slug format; `:parent_org_id` is left out of this changeset on
  # purpose so the derived-parent rule can't flash an error at someone who
  # is still typing.
  def handle_event("validate_org", %{"org" => params}, socket) do
    {:noreply, apply_params(socket, params)}
  end

  # The ring is 72 `phx-click` targets rather than an input, so a pick does
  # not go through `phx-change`. It re-enters the SAME path a keystroke
  # does: merge into the params already on the form, rebuild the one
  # changeset, recompute the preview. The visible number input carries the
  # value, so the ring is not the only way to set a hue — a ring alone is
  # not operable from a keyboard.
  def handle_event("pick_hue", %{"hue" => hue}, socket) do
    params = Map.put(current_params(socket), "color_hue", hue)
    {:noreply, apply_params(socket, params)}
  end

  def handle_event("clear_hue", _params, socket) do
    params = Map.put(current_params(socket), "color_hue", "")
    {:noreply, apply_params(socket, params)}
  end

  def handle_event("create_org", %{"org" => params}, socket) do
    case Tenancy.create_org(socket.assigns[:current_user_record], form_attrs(params)) do
      {:ok, org} ->
        {:noreply,
         socket
         |> assign(:show_create_sheet, false)
         |> assign_blank_form()
         |> load_orgs()
         |> put_flash(:info, created_flash(org))}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Duplicate slug lands HERE, on the `:slug` field, because
        # `Org.changeset/2` pairs `unique_constraint(:slug)` with the real
        # index. Keep the sheet open so the error is next to the input.
        {:noreply,
         socket
         |> assign(:org_form, to_form(changeset, as: "org"))
         |> assign(:show_create_sheet, true)}

      {:error, :unauthorized} ->
        # Unreachable through the `:ensure_admin` route gate, which is the
        # point: this is the second half of defence in depth, not dead code.
        {:noreply,
         socket
         |> assign(:show_create_sheet, false)
         |> put_flash(:error, "You don't have permission to create orgs.")}
    end
  end

  # ── Assign helpers ─────────────────────────────────────────────────────

  defp assign_blank_form(socket) do
    socket
    |> assign(:org_form, to_form(Org.changeset(%Org{}, %{}), as: "org"))
    |> assign_preview(nil)
  end

  # One path for every edit — a keystroke, a ring click, the clear button.
  # They differ only in which key they put into `params`.
  defp apply_params(socket, params) do
    # `:validate` is what makes errors render, and it is applied ONLY once
    # the operator has typed into a text field. Picking a colour is a legal
    # first move — the ring is above the fold and invites one — and without
    # this guard that first click answers with "can't be blank" against Name
    # and Slug, scolding someone for not having reached fields yet. An error
    # is a report on what they did, not a preview of what they have not.
    action = if typed_anything?(params), do: :validate, else: nil

    changeset =
      %Org{}
      |> Org.changeset(form_attrs(params))
      |> Map.put(:action, action)

    socket
    |> assign(:org_form, to_form(changeset, as: "org"))
    |> assign_preview(picked_hue(params))
  end

  defp typed_anything?(params) do
    Enum.any?(["name", "slug"], fn key ->
      params |> Map.get(key, "") |> to_string() |> String.trim() != ""
    end)
  end

  defp current_params(socket) do
    case socket.assigns.org_form.params do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp load_orgs(socket) do
    assign(socket, :orgs, Tenancy.list_orgs_in_priority_order())
  end

  # Only `name`, `slug` and `color_hue` cross from the wire into the write.
  # Parentage is still derived inside `create_org/2`; dropping the key
  # entirely is what makes that derivation fire, so this stays a `take` and
  # not a `drop`.
  #
  # `color_chroma` is added SERVER-SIDE, not taken from the wire: there is
  # one control and it picks a hue, so a chroma arriving in params would be
  # a value no operator chose. It is written explicitly rather than left to
  # the column default because a default is a fourth place naming the
  # number — and the one that was there disagreed with the other three. An
  # org with no hue gets no chroma either; a chroma without a hue colours
  # nothing and would be a stored value that means nothing.
  defp form_attrs(params) when is_map(params) do
    attrs = Map.take(params, ["name", "slug", "color_hue"])

    case picked_hue(params) do
      nil -> attrs
      _hue -> Map.put(attrs, "color_chroma", @chroma)
    end
  end

  # ── Preview ────────────────────────────────────────────────────────────

  # Everything the preview panel prints is computed HERE and passed down as
  # data. None of it is computed in JS: the numbers an operator reads off
  # this panel are the numbers the server will store and the rail will
  # paint, and a second implementation in the browser is a second answer.
  defp assign_preview(socket, nil) do
    socket
    |> assign(:picked_hue, nil)
    |> assign(:preview, nil)
    |> assign(:hue_conflicts, [])
  end

  defp assign_preview(socket, hue) do
    ramp = ScopeColor.derive(hue, @chroma)

    socket
    |> assign(:picked_hue, hue)
    |> assign(:preview, %{
      ramp: ramp,
      grounds: [
        preview_ground(ramp, :light, "Light theme"),
        preview_ground(ramp, :dark, "Dark theme")
      ]
    })
    |> assign(:hue_conflicts, conflicts_for(socket.assigns.orgs, hue))
  end

  @doc """
  One theme's half of the preview: every cell the solver solved for that
  theme, and the worst of them.

  Design ruling, task 01a09287: the panel prints the worst cell and names
  it. An operator does not need a contrast table; they need to know whether
  the colour holds everywhere it will appear, and a bare number invites a
  best-case reading of a value that is only true in one place.

  EVERYTHING here is read off the ramp, and nothing is recomputed. This
  panel used to carry its own copy of the cell table while `ScopeColor`
  solved against a different one, so it printed the worst of four while the
  solver hit the best of four, and the gap between the two definitions
  showed up as a flat 3.74-3.81 at every hue on the circle in light. A
  shortfall that does not move with hue is a constant offset between two
  tables, not a property of any colour. `ScopeColor.cells/1` is the one
  enumeration, `derive/2` solves every cell in it, and this prints
  `worst_light` / `worst_dark` from that solve, so the number an operator
  approves is the number the solver met.

  Each cell is painted with the exact bytes it was measured on: its surface,
  its opaque tint and its label. `panel_style` is the theme's `base-100`,
  read from the same cells.
  """
  def preview_ground(ramp, theme, name) do
    cells = Map.fetch!(ramp.cells, theme)
    pane = Enum.find(cells, &(&1.surface == "base-100"))

    %{
      key: theme,
      name: name,
      panel_style: "background-color:#{pane.color}",
      text_color: pane.label,
      cells: cells,
      worst: if(theme == :light, do: ramp.worst_light, else: ramp.worst_dark)
    }
  end

  @doc false
  def format_contrast(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  @doc """
  The list-row swatch colour for an org, from its own stored hue.

  Uses the org's `color_chroma` when it has one, and #{@chroma} otherwise —
  the same fallback `Tenancy.scope_slug_entries/1` applies — and the org's
  `color_lightness` when it has one, so the swatch matches what the rail
  paints for the six shipped orgs (hooli's fill is 80%, not the 72%
  default; task 01a09333-d374 stage 5).
  """
  def org_fill(%{color_hue: hue} = org) when is_integer(hue) do
    lightness = Map.get(org, :color_lightness) || ScopeColor.default_fill_lightness()
    ScopeColor.derive(hue, org.color_chroma || @chroma, lightness).fill
  end

  defp picked_hue(params) do
    params
    |> Map.get("color_hue")
    |> normalize_hue()
  end

  defp normalize_hue(value) when is_integer(value) and value >= 0 and value < 360, do: value

  defp normalize_hue(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {hue, ""} -> normalize_hue(hue)
      _ -> nil
    end
  end

  defp normalize_hue(_), do: nil

  # ── Template helpers (imported via `use PlatformWeb, :live_view`) ───────

  @doc """
  Orgs whose hue is within #{@proximity_degrees}° of `hue`, nearest first.

  Distance is measured ON THE CIRCLE: hue 5 and hue 355 are 10 degrees
  apart, not 350. A linear subtraction here would silently stop warning
  across the wrap point, which is one sixth of the notches on the ring.
  """
  def conflicts_for(orgs, hue) when is_integer(hue) do
    orgs
    |> Enum.filter(&is_integer(&1.color_hue))
    |> Enum.map(&%{org: &1, distance: hue_distance(hue, &1.color_hue)})
    |> Enum.filter(&(&1.distance <= @proximity_degrees))
    |> Enum.sort_by(& &1.distance)
  end

  def conflicts_for(_orgs, _hue), do: []

  @doc false
  def hue_distance(a, b) do
    diff = abs(rem(a - b, 360))
    min(diff, 360 - diff)
  end

  @doc """
  The 72 ring stops, each with the colour it will actually paint.

  Drawn at `min(reachable chroma, #{@chroma})` rather than a flat
  #{@chroma} everywhere. More than half the hue circle is outside sRGB at
  the chromas the shipped orgs use, so a flat band asks the browser to clip
  — and once it clips, two visibly different picks can paint as the same
  colour, which is the one thing the ring exists to prevent. Clamping to
  what is reachable means the swatch an operator clicks is the colour the
  rail will show, and the low-chroma arc looks duller because it IS duller.
  """
  def ring_stops do
    for index <- 0..71 do
      hue = index * 5
      chroma = min(ScopeColor.max_chroma(@ring_lightness, hue), @chroma)

      %{
        hue: hue,
        color: "oklch(#{trunc(@ring_lightness * 100)}% #{Float.round(chroma, 4)} #{hue})",
        path: arc_path(@ring_radius, hue - 2.5, hue + 2.5)
      }
    end
  end

  @doc false
  def ring_notch(hue), do: radial_path(hue, @ring_radius + 11, @ring_radius + 16)

  @doc false
  def ring_handle(hue), do: ring_point(@ring_radius, hue)

  @doc false
  def ring_point(radius, hue) do
    # Hue 0 at 3 o'clock, increasing ANTI-clockwise, which is how every
    # colour wheel a designer has ever seen is oriented. SVG's y axis points
    # down, so that is a negated angle here.
    radians = -hue * :math.pi() / 180.0
    {@ring_center + radius * :math.cos(radians), @ring_center + radius * :math.sin(radians)}
  end

  defp arc_path(radius, from_hue, to_hue) do
    {x1, y1} = ring_point(radius, from_hue)
    {x2, y2} = ring_point(radius, to_hue)
    "M #{f(x1)} #{f(y1)} A #{radius} #{radius} 0 0 0 #{f(x2)} #{f(y2)}"
  end

  defp radial_path(hue, from_radius, to_radius) do
    {x1, y1} = ring_point(from_radius, hue)
    {x2, y2} = ring_point(to_radius, hue)
    "M #{f(x1)} #{f(y1)} L #{f(x2)} #{f(y2)}"
  end

  defp f(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  @doc """
  The flash shown after a successful create.

  It used to promise "a follow-up code change" before the org could appear
  on the rail. Both halves of that are now false — stage 2 gave every
  active org a chip, and this stage gives it a colour with no deploy — so
  the message states what actually happened instead.
  """
  def created_flash(%{color_hue: hue} = org) when is_integer(hue),
    do: "Created #{org.name}. Its scope colour is live on the rail at hue #{hue}."

  def created_flash(org),
    do: "Created #{org.name}. No colour set — its rail chip renders unstyled until one is."

  @doc """
  True when the org shows a chip on the Tasks scope rail for its members.

  Since task 01a09287 stage 2 that is every ACTIVE org: the rail reads
  `Tenancy.scope_slug_entries/1`, which is `list_active_tenants_for_user/1`
  mapped to entries, so the only thing that keeps an org off the rail is
  `archived_at`. This used to test membership of `Tasks.scope_keys/0` and
  was false for every org an admin could create — the failure that task
  existed to fix.
  """
  def on_scope_rail?(%{archived_at: nil}), do: true
  def on_scope_rail?(_), do: false

  @doc false
  def root_org?(%{parent_org_id: nil}), do: true
  def root_org?(_), do: false
end
