defmodule PlatformWeb.AdminOrgsLive do
  @moduledoc """
  Orgs — the admin surface that makes `Platform.Tenancy.create_org/2`
  reachable by a human (task 019ffe9d stage 4).

  Stage 1 shipped the write; until this surface existed the only caller was
  a code path nobody could reach from a browser, so onboarding a client
  still meant shipping a migration. This is the form that removes the
  migration.

  ## What this surface deliberately does NOT do

  It does not finish onboarding, and the copy says so out loud. An org
  created here is a real, selectable tenant row, but it has no scope colour
  ramp (six hand-authored CSS utilities plus two AA-measured label values
  per slug) and it is not in `Platform.Tasks.scope_keys/0`, which
  `TasksLive.active_scope_keys/1` intersects against — so it will NOT
  appear on the Tasks scope rail until a follow-up code change ships. That
  silent invisibility is the failure this ticket exists to fix, so the list
  badges every org with its rail status and the create sheet warns before
  submit rather than after.

  ## Authorization — defence in depth

    * The route lives in the `:admin` `live_session` in
      `PlatformWeb.Router`, whose `PlatformWeb.LiveAuth.on_mount(:ensure_admin, ...)`
      hook halt-redirects a non-admin mount.
    * AND the write itself re-checks: the acting user
      (`@current_user_record`, assigned by `LiveAuth.on_mount(:default, ...)`)
      is threaded into `Tenancy.create_org/2` as the actor, and
      `Lifecycle.with_fabrikam_admin_authz/2` answers `{:error, :unauthorized}`
      for anyone who is not a root-org admin. Neither check is load-bearing
      alone.

  Parentage is NOT a form field: `create_org/2` derives `:parent_org_id`
  from the single root org. The submit path passes only `name` and `slug`
  through, so a crafted `org[parent_org_id]` on the wire cannot reparent
  anything or attempt a second root (which the `orgs_single_root` partial
  unique index would refuse anyway).
  """
  use PlatformWeb, :live_view

  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

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
    changeset =
      %Org{}
      |> Org.changeset(form_attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :org_form, to_form(changeset, as: "org"))}
  end

  def handle_event("create_org", %{"org" => params}, socket) do
    case Tenancy.create_org(socket.assigns[:current_user_record], form_attrs(params)) do
      {:ok, org} ->
        {:noreply,
         socket
         |> assign(:show_create_sheet, false)
         |> assign_blank_form()
         |> load_orgs()
         |> put_flash(
           :info,
           "Created #{org.name}. It has no scope colour yet — it will not appear on the Tasks scope rail until a follow-up code change ships."
         )}

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
    assign(socket, :org_form, to_form(Org.changeset(%Org{}, %{}), as: "org"))
  end

  defp load_orgs(socket) do
    assign(socket, :orgs, Tenancy.list_orgs_in_priority_order())
  end

  # Only `name` and `slug` cross from the wire into the write. Parentage is
  # derived inside `create_org/2`; dropping the key entirely is what makes
  # that derivation fire.
  defp form_attrs(params) when is_map(params), do: Map.take(params, ["name", "slug"])

  # ── Template helpers (imported via `use PlatformWeb, :live_view`) ───────

  @doc """
  True when the org's slug is registered in `Platform.Tasks.scope_keys/0`,
  i.e. it survives `TasksLive.active_scope_keys/1`'s intersection and can
  show a chip on the scope rail. False means the row exists but is
  invisible on the rail pending a code change.
  """
  def on_scope_rail?(slug) when is_binary(slug) do
    Enum.any?(Tasks.scope_keys(), &(Atom.to_string(&1) == slug))
  end

  def on_scope_rail?(_), do: false

  @doc false
  def root_org?(%{parent_org_id: nil}), do: true
  def root_org?(_), do: false
end
