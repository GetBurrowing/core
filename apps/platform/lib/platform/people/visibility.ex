defmodule Platform.People.Visibility do
  @moduledoc """
  People-side path helpers and visibility policy for the two storage tiers.

  Every person has a card at `org/page/people/<slug>.md` (tier `card`, no
  `readers:`, readable by everyone) and a private page at
  `org/page/people/<slug>/private.md` (tier `private`, `readers:
  [subject, admins]`, `subject_user_id` when the person has an account).

  This module only decides WHAT the keys are; `Platform.Org.Wiki.Readers`
  enforces them without knowing this module exists. People sets, Wiki
  honours, and the dependency points one way.
  """

  @prefix "org/page/people/"
  @index_path "org/page/people/index.md"
  @private_re ~r{\Aorg/page/people/[^/]+/private\.md\z}
  @card_re ~r{\Aorg/page/people/(?<slug>[^/]+)\.md\z}

  @type tier :: :card | :private | :index | :unknown

  @doc "The page prefix every people page lives under."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The generated roster index path."
  @spec index_path() :: String.t()
  def index_path, do: @index_path

  @doc "The card path for a slug."
  @spec card_path(String.t()) :: String.t()
  def card_path(slug) when is_binary(slug), do: @prefix <> slug <> ".md"

  @doc "The private-tier path for a slug."
  @spec private_path(String.t()) :: String.t()
  def private_path(slug) when is_binary(slug), do: @prefix <> slug <> "/private.md"

  @doc "Is this path a private-tier people page?"
  @spec private_path?(String.t()) :: boolean()
  def private_path?(path) when is_binary(path), do: Regex.match?(@private_re, path)
  def private_path?(_), do: false

  @doc """
  The frontmatter keys a private page carries. With an account the subject
  may read their own page; without one, only admins (and agents, which the
  Wiki never restricts) can.
  """
  @spec private_frontmatter(String.t() | nil) :: %{String.t() => term()}
  def private_frontmatter(user_id) when is_binary(user_id) and user_id != "" do
    %{"readers" => ["subject", "admins"], "subject_user_id" => user_id}
  end

  def private_frontmatter(_no_account), do: %{"readers" => ["admins"]}

  @doc """
  Classify a people path by tier: `:private`, `:index`, `:card`, or
  `:unknown` for anything outside the grammar (including non-people paths).
  """
  @spec tier_of(String.t()) :: tier()
  def tier_of(path) when is_binary(path) do
    cond do
      path == @index_path -> :index
      private_path?(path) -> :private
      Regex.match?(@card_re, path) -> :card
      true -> :unknown
    end
  end

  def tier_of(_), do: :unknown

  @doc "The slug of a card or private path; `nil` for anything else."
  @spec slug_of(String.t()) :: String.t() | nil
  def slug_of(path) when is_binary(path) do
    case tier_of(path) do
      :card -> Regex.named_captures(@card_re, path)["slug"]
      :private -> path |> String.trim_leading(@prefix) |> String.split("/") |> Enum.at(0)
      _ -> nil
    end
  end

  def slug_of(_), do: nil

  @doc """
  May an agent surface `path` in this tool-call `context`?

  Only the private tier is ever refused. A private page may be surfaced when
  the call has no `:space_id` (a system or execution dispatch, proactive
  work) or when the space is a dm / group / execution / system space AND the
  page's `subject_user_id` is a participant of it. A channel refuses
  regardless, as does any space the subject is not in, and so does a space
  the engine cannot resolve. The answer never depends on whether the page
  exists in a way a caller can tell apart: an absent page has no subject, so
  it is refused exactly like a present page whose subject is elsewhere.

  `context[:workspace_id]` scopes the page lookup when present.
  """
  @spec agent_context_allows?(String.t(), map() | nil) :: boolean()
  def agent_context_allows?(path, context) when is_binary(path) do
    if private_path?(path) do
      case context_space_id(context) do
        nil -> true
        space_id -> space_allows_private?(space_id, path, context_workspace_id(context))
      end
    else
      true
    end
  end

  def agent_context_allows?(_, _), do: false

  @private_space_kinds ~w(dm group execution system)

  defp space_allows_private?(space_id, path, workspace_id) do
    case Platform.Chat.get_space(space_id) do
      %Platform.Chat.Space{kind: kind} when kind in @private_space_kinds ->
        subject = subject_user_id(path, workspace_id)

        is_binary(subject) and Platform.UUID.valid?(subject) and
          Platform.Chat.participant?(space_id, subject)

      _channel_or_unknown ->
        false
    end
  end

  defp subject_user_id(path, workspace_id) do
    case Platform.Org.Wiki.get_page(path, workspace_id: workspace_id) do
      %{frontmatter: %{} = frontmatter} -> Map.get(frontmatter, "subject_user_id")
      _ -> nil
    end
  end

  defp context_space_id(%{} = context) do
    case Map.get(context, :space_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp context_space_id(_), do: nil

  defp context_workspace_id(%{} = context), do: Map.get(context, :workspace_id)
  defp context_workspace_id(_), do: nil
end
