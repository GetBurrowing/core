defmodule Platform.Theming do
  @moduledoc """
  Org themes (task 01a1557a-fe9b, Burrow redesign 24, stage 1): colour themes
  a root admin authors for an org, and publishes once every contrast pair
  clears its floor in both modes.

  Every write re-checks `Platform.Tenancy.root_admin?/1` on the actor it is
  given, at the call, and returns `{:error, :unauthorized}` otherwise; no
  caller's earlier check is trusted. Reads for people (not admins) go through
  `list_published_for_user/1`, which only returns published themes of the
  orgs the person is a member of.

  A theme is named for a person's theme preference by `OrgTheme.preset_id/1`,
  `"org-" <> id`.

  Distinct from `Platform.Branding` (install-wide colours that style the
  Burrow preset only); nothing here reads or writes `install_branding`.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Theming.Ledger
  alias Platform.Theming.OrgTheme
  alias Platform.Theming.Presets

  @modes ["dark", "light"]

  @type actor :: %{id: binary()} | nil
  @type error :: {:error, :unauthorized | :not_found | :published | Ecto.Changeset.t()}

  # ── reads ───────────────────────────────────────────────────────────────

  @doc "Every theme of `org_id`, drafts included, by name. Root admins only."
  @spec list_org_themes(actor(), binary()) :: {:ok, [OrgTheme.t()]} | {:error, :unauthorized}
  def list_org_themes(actor, org_id) when is_binary(org_id) do
    with :ok <- authorize(actor) do
      {:ok, Repo.all(from(t in OrgTheme, where: t.org_id == ^org_id, order_by: t.name))}
    end
  end

  @doc "One theme by id. Root admins only."
  @spec get_theme(actor(), binary()) :: {:ok, OrgTheme.t()} | error()
  def get_theme(actor, id) when is_binary(id) do
    with :ok <- authorize(actor), do: fetch(id)
  end

  @doc """
  The published themes of every org `user` is a member of, by name. A person
  in no org gets none.
  """
  @spec list_published_for_user(actor()) :: [OrgTheme.t()]
  def list_published_for_user(%{id: user_id}) when is_binary(user_id) do
    from(t in OrgTheme,
      where:
        t.status == "published" and
          t.org_id in subquery(Tenancy.viewer_org_ids_query(user_id)),
      order_by: [t.name, t.id]
    )
    |> Repo.all()
  end

  def list_published_for_user(_), do: []

  @doc """
  The preset ids (`OrgTheme.preset_id/1`) of `list_published_for_user/1`:
  the org presets `Platform.Accounts.ThemePreference` may accept or keep for
  this person.
  """
  @spec visible_preset_ids(actor()) :: [String.t()]
  def visible_preset_ids(user),
    do: user |> list_published_for_user() |> Enum.map(&OrgTheme.preset_id/1)

  @doc "The contrast ledger of `theme` in `mode` (`Platform.Theming.Ledger`)."
  @spec ledger(map(), String.t()) :: [Ledger.row()]
  def ledger(theme, mode) when mode in @modes, do: Ledger.ledger(theme, mode)

  # ── writes ──────────────────────────────────────────────────────────────

  @doc """
  Creates a draft in `org_id`. A missing `light`, `dark` or `shape` is seeded
  from the Burrow preset, so a draft always holds a complete palette.
  """
  @spec create_draft(actor(), binary(), map()) :: {:ok, OrgTheme.t()} | error()
  def create_draft(actor, org_id, attrs) when is_binary(org_id) and is_map(attrs) do
    with :ok <- authorize(actor) do
      base = Presets.base()

      %OrgTheme{
        org_id: org_id,
        status: "draft",
        light: base.light,
        dark: base.dark,
        shape: base.shape
      }
      |> OrgTheme.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Edits a draft's palettes, shape, default mode or name. A published theme is refused."
  @spec update_draft(actor(), OrgTheme.t(), map()) :: {:ok, OrgTheme.t()} | error()
  def update_draft(actor, %OrgTheme{} = theme, attrs) when is_map(attrs) do
    with :ok <- authorize(actor),
         {:ok, current} <- fetch(theme.id),
         :ok <- draft(current) do
      current |> OrgTheme.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Renames a theme, draft or published."
  @spec rename(actor(), OrgTheme.t(), String.t()) :: {:ok, OrgTheme.t()} | error()
  def rename(actor, %OrgTheme{} = theme, name) when is_binary(name) do
    with :ok <- authorize(actor),
         {:ok, current} <- fetch(theme.id) do
      current |> OrgTheme.changeset(%{name: name}) |> Repo.update()
    end
  end

  @doc "Copies a theme into a new draft in the same org, named `name` or \"<name> (copy)\"."
  @spec duplicate(actor(), OrgTheme.t(), String.t() | nil) :: {:ok, OrgTheme.t()} | error()
  def duplicate(actor, %OrgTheme{} = theme, name \\ nil) do
    with :ok <- authorize(actor),
         {:ok, current} <- fetch(theme.id) do
      %OrgTheme{org_id: current.org_id, status: "draft"}
      |> OrgTheme.changeset(%{
        name: name || copy_name(current.name),
        default_mode: current.default_mode,
        light: current.light,
        dark: current.dark,
        shape: current.shape
      })
      |> Repo.insert()
    end
  end

  @doc "Deletes a theme."
  @spec delete(actor(), OrgTheme.t()) :: {:ok, OrgTheme.t()} | error()
  def delete(actor, %OrgTheme{} = theme) do
    with :ok <- authorize(actor),
         {:ok, current} <- fetch(theme.id) do
      Repo.delete(current)
    end
  end

  @doc """
  Publishes a theme. Refused with `{:error, {:contrast, rows}}` while any
  ledger row fails in either mode; each failing row carries its `mode`.
  """
  @spec publish(actor(), OrgTheme.t()) ::
          {:ok, OrgTheme.t()} | {:error, {:contrast, [map()]}} | error()
  def publish(actor, %OrgTheme{} = theme) do
    with :ok <- authorize(actor),
         {:ok, current} <- fetch(theme.id),
         :ok <- clears_every_pair(current) do
      current
      |> OrgTheme.publish_changeset(actor.id, DateTime.utc_now())
      |> Repo.update()
    end
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp authorize(actor) do
    if Tenancy.root_admin?(actor), do: :ok, else: {:error, :unauthorized}
  end

  # A malformed id is a miss, never an Ecto.Query.CastError: `get_theme/2`
  # takes an id a later LiveView will read from params.
  defp fetch(id) do
    with true <- Platform.UUID.valid?(id),
         %OrgTheme{} = theme <- Repo.get(OrgTheme, id) do
      {:ok, theme}
    else
      _ -> {:error, :not_found}
    end
  end

  defp draft(%OrgTheme{status: "draft"}), do: :ok
  defp draft(_), do: {:error, :published}

  defp clears_every_pair(theme) do
    failing =
      for mode <- @modes,
          row <- Ledger.ledger(theme, mode),
          not row.pass?,
          do: Map.put(row, :mode, mode)

    if failing == [], do: :ok, else: {:error, {:contrast, failing}}
  end

  defp copy_name(name) do
    suffix = " (copy)"
    String.slice(name, 0, 80 - String.length(suffix)) <> suffix
  end
end
