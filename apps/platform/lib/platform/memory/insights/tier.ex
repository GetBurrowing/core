defmodule Platform.Memory.Insights.Tier do
  @moduledoc """
  Reversibility tiers for dreaming insights. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 2.

  `classify/1` answers `:reversible` or `:needs_call`, and it DEFAULTS TO
  DENY: `:reversible` is returned only when every condition below holds,
  and anything it does not recognise is `:needs_call`.

    1. `action_type` is one of `page_edit`, `briefing`, `question`, `task`.
    2. The `action` is a map.
    3. The addressee, when there is one, is a NON-EXTERNAL member of the
       insight's org (`org_id/1`). A raw email address in the `addressee`
       attribute, an `addressee` that resolved to nobody, an external user
       and a guest (an `external` membership) are all `:needs_call`.
    4. For a `page_edit`: the target page exists, no hunk is delete-shaped
       (`Platform.Memory.Insights.Hunks.delete_shaped?/1`), and, when the
       hunks apply to the page as it is now, the resulting content is not
       blank. A hunk that no longer applies does not change the tier: the
       edit cannot run anyway, and `Platform.Memory.Insights.Actions`
       refuses it as `:stale` with the page untouched.

  The tier is stored at ingest and RE-CHECKED at execute time, because the
  page, the membership and the addressee can all change in between.

  ## What is not here

  This slice has no executor for mail or for permission changes, so "never
  auto-run an outward or a permission action" holds for them by absence:
  there is no `action_type` that names one, and an unknown `action_type`
  is `:needs_call`.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Memory.Insights.Hunks
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @reversible_types ~w(page_edit briefing question task)

  @type tier :: :reversible | :needs_call

  @doc "Classify an insight (a `%Platform.Memory.Insight{}` or a map with its fields)."
  @spec classify(term()) :: tier()
  def classify(%{action_type: type, action: action} = insight)
      when type in @reversible_types and is_map(action) do
    if addressee_ok?(insight) and shape_ok?(type, insight),
      do: :reversible,
      else: :needs_call
  end

  def classify(_insight), do: :needs_call

  @doc "The tier as the string stored in `memory_insights.tier`."
  @spec label(tier()) :: String.t()
  def label(:reversible), do: "reversible"
  def label(:needs_call), do: "needs_call"

  @doc """
  The org an insight belongs to: its `org_id`, else the install's root org.
  """
  @spec org_id(map()) :: binary() | nil
  def org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id

  def org_id(_insight) do
    case Platform.Tenancy.get_root_org() do
      %{id: id} -> id
      nil -> nil
    end
  end

  # ── addressee ────────────────────────────────────────────────────────

  defp addressee_ok?(insight) do
    raw = Map.get(insight.action, "addressee")
    user_id = Map.get(insight, :addressee_user_id)

    cond do
      email?(raw) -> false
      is_binary(user_id) -> internal_member?(user_id, org_id(insight))
      # Named, but nobody it resolved to: not established as a member.
      is_binary(raw) -> false
      true -> true
    end
  end

  defp email?(raw) when is_binary(raw), do: String.contains?(raw, "@")
  defp email?(_raw), do: false

  defp internal_member?(user_id, org_id) when is_binary(org_id) do
    Platform.UUID.valid?(user_id) and
      Repo.exists?(
        from(m in OrgMembership,
          where: m.user_id == ^user_id and m.org_id == ^org_id and m.external == false
        )
      )
  end

  defp internal_member?(_user_id, _org_id), do: false

  # ── shape ────────────────────────────────────────────────────────────

  defp shape_ok?("page_edit", insight) do
    target = Map.get(insight.action, "target")
    hunks = Map.get(insight.action, "hunks")

    with true <- is_binary(target),
         false <- Hunks.delete_shaped?(hunks),
         %{content: content} <-
           Wiki.get_page(target, workspace_id: Map.get(insight, :workspace_id)) do
      case Hunks.apply_all(content || "", hunks) do
        {:ok, result} -> String.trim(result) != ""
        :stale -> true
      end
    else
      _ -> false
    end
  end

  defp shape_ok?(_type, _insight), do: true
end
