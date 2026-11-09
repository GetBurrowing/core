defmodule Platform.Onboarding.OwnerHandover do
  @moduledoc """
  What happens the moment a new install's owner completes the sign-in that
  began at the hand-over link (`PlatformWeb.AuthController.handover/2`).

  Two things, both so the owner's first minutes are not spent in the wrong
  place or in an empty app:

    1. The owner is marked past first run
       (`Platform.Onboarding.FirstRunGoal.mark_owner/1`). Otherwise an owner
       who opens `/` before finishing `/setup/connect-ai` is redirected to
       `/start`, the member goal box.
    2. If the install has no project at all, a first project and a channel,
       both named after the root org (whose name comes from the install
       manifest), are created so the sidebar is not empty. The owner is the
       channel's admin (`Chat.create_space/1` seats `created_by`).

  Idempotent: the project and channel are created only while the install has
  no project, archived ones included, so a second hand-over, a re-run or an
  install whose people already made (or deleted down to) their own projects
  is left alone. Concurrent runs lose on the project and space slug unique
  indexes and just log.

  Projects carry no owner column; the project belongs to the root org and the
  owner is seated on its channel.

  `complete/1` never raises and always returns `:ok`: it runs inside the OIDC
  callback, and sign-in must never fail because of onboarding niceties.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Chat
  alias Platform.Onboarding.FirstRunGoal
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy

  @doc "Run both steps for `user`. Logs failures; returns `:ok`."
  @spec complete(map()) :: :ok
  def complete(%{id: user_id} = user) when is_binary(user_id) do
    if Platform.UUID.valid?(user_id), do: run(user), else: :ok
  end

  def complete(_), do: :ok

  defp run(user) do
    log_failure(:mark_owner, FirstRunGoal.mark_owner(user))
    log_failure(:first_project, ensure_first_project(user, Tenancy.get_root_org()))
    :ok
  rescue
    error ->
      Logger.warning("[OwnerHandover] not completed: #{Exception.message(error)}")
      :ok
  end

  defp log_failure(_step, :ok), do: :ok
  defp log_failure(_step, :exists), do: :ok

  defp log_failure(step, {:error, reason}),
    do: Logger.warning("[OwnerHandover] #{step} failed: #{inspect(reason)}")

  defp ensure_first_project(_user, nil), do: {:error, :no_root_org}

  defp ensure_first_project(user, org) do
    if Repo.exists?(from(p in Project, select: 1)) do
      :exists
    else
      with {:ok, _project} <- Tasks.create_project(%{name: org.name, org_id: org.id}),
           {:ok, _space} <- create_channel(user, org) do
        :ok
      end
    end
  end

  defp create_channel(user, org) do
    Chat.create_space(%{
      name: org.name,
      slug: channel_slug(org.name),
      kind: "channel",
      org_id: org.id,
      created_by: user.id,
      metadata: %{"origin" => "owner_handover"}
    })
  end

  # The settings form's slug rule; never empty, never a reserved prefix.
  defp channel_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/[\s-]+/, "-")
      |> String.trim("-")

    cond do
      base == "" -> "home"
      Chat.reserved_slug_prefix?(base <> "-") -> "home-" <> base
      true -> base
    end
  end
end
