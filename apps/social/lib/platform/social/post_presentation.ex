defmodule Platform.Social.PostPresentation do
  @moduledoc "Read-authorized, bounded identity for legacy post links. Never an approval grant."

  alias Platform.{Accounts, Repo, Social}
  alias Platform.Social.{Account, Approvals, Clip, Idea, Post, Profile, Studio}

  @doc "Load-local authority only. Never retain this context across events or requests."
  def authorize(viewer, []), do: %{viewer: viewer, profiles: %{}}

  def authorize(viewer, profile_ids) do
    profiles =
      with {:user, id} <- viewer,
           true <- Platform.UUID.valid?(id),
           %{archived_at: nil} = user <- Accounts.get_user(id) do
        user
        |> Social.list_profiles_for_user()
        |> Enum.filter(&(&1.id in profile_ids and Studio.require_social_use(id, &1) == :ok))
        |> Map.new(&{&1.id, &1})
      else
        _ -> %{}
      end

    %{viewer: viewer, profiles: profiles}
  end

  @doc "Fresh current read authority, independent of approval authority."
  def read(%Post{id: id}, viewer) do
    with true <- Platform.UUID.valid?(id),
         %Post{} = post <- Repo.get(Post, id),
         %Account{} = account <- Repo.get(Account, post.account_id) do
      describe(post, account, authorize(viewer, [account.profile_id]))
    else
      _ -> nil
    end
  end

  def read(_, _), do: nil

  @doc "Presentation within the current load, with per-post account/profile binding."
  def describe(%Post{flow: "legacy", account_id: id} = post, %Account{id: id} = account, context) do
    case context.profiles[account.profile_id] do
      %Profile{} = profile ->
        %{
          title: title(post, account),
          post_url: Approvals.queue_url(post, profile) <> "&post=" <> post.id,
          post_link_label:
            if(post.status in ~w(quality_review needs_approval),
              do: "Open in Queue",
              else: "View post details"
            )
        }

      _ ->
        nil
    end
  end

  def describe(_, _, _), do: nil

  @doc "Exact link only for the current reader; legacy navigation otherwise."
  def url(post, profile, viewer) do
    case read(post, viewer) do
      %{post_url: url} -> url
      _ -> Approvals.queue_url(post, profile)
    end
  end

  @doc "Display title only; callers must establish read authority before exposing it."
  def title(%Post{} = post, %Account{} = account) do
    clip = post.clip_id && Repo.get_by(Clip, id: post.clip_id, profile_id: account.profile_id)
    idea = post.idea_id && Repo.get_by(Idea, id: post.idea_id, profile_id: account.profile_id)

    cond do
      clip && present?(clip.title) ->
        prefix = if present?(clip.episode_code), do: clip.episode_code <> " · ", else: ""
        bounded(prefix <> clip.title)

      idea && present?(idea.title) ->
        bounded(idea.title)

      caption = caption_title(post.body) ->
        bounded(caption)

      true ->
        Approvals.platform_label(account.platform) <> " post"
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp caption_title(body) do
    (body || "")
    |> String.split(~r/\R/u)
    |> Enum.find_value(fn line ->
      line =
        line
        |> String.replace(~r/https?:\/\/\S+/u, "")
        |> String.replace(~r/(?:^|\s)#[\p{L}\p{N}_]+/u, "")
        |> String.trim()

      if line != "", do: sentence_or_line(line)
    end)
  end

  defp sentence_or_line(line) do
    case Regex.run(~r/^(.+?[.!?])(?:\s|$)/u, line, capture: :all_but_first) do
      [sentence] when byte_size(sentence) <= 280 ->
        if String.length(sentence) <= 70, do: {:sentence, sentence}, else: line

      _ ->
        line
    end
  end

  defp bounded({:sentence, sentence}), do: sentence

  defp bounded(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= 60 do
      text
    else
      prefix = String.slice(text, 0, 60)

      prefix =
        if String.contains?(prefix, " "),
          do: String.replace(prefix, ~r/\s+\S*$/u, ""),
          else: prefix

      String.trim_trailing(prefix) <> "…"
    end
  end
end
