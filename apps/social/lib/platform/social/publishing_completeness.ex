defmodule Platform.Social.PublishingCompleteness do
  @moduledoc """
  Required fields for legacy publishing review. This is a completeness check,
  not authorization or an approved-content snapshot. Writers call it after
  their existing authority checks; approval samples the clock after locking.
  It reads file facts only and never signs media or contacts a vendor.
  """
  alias Ecto.Changeset
  alias Platform.Social.{Account, MediaRules, OrgFiles, PlatformLimits, PlatformOptions}

  def check(post, account, now \\ DateTime.utc_now()) do
    errors =
      title_errors(post, account) ++
        text_errors(post, account) ++
        media_errors(post, account) ++
        cover_errors(post) ++
        option_errors(post, account) ++ time_errors(post, now) ++ account_errors(account)

    if errors == [], do: :ok, else: {:error, {:incomplete_post, errors}}
  end

  # The existing draft-only card is a copy/by-hand request, not publishing review.
  # Approval still runs check/3 and refuses this account mode.
  def submission(%Changeset{}, %Account{approval_mode: "draft_only"}), do: :ok
  def submission(%Changeset{valid?: false}, _account), do: :ok

  def submission(%Changeset{} = changeset, account) do
    post = Changeset.apply_changes(changeset)

    new_request? =
      is_nil(changeset.data.id) or changeset.data.status != "needs_approval" or
        Map.has_key?(changeset.params || %{}, "status")

    if post.flow == "legacy" and post.status == "needs_approval" and new_request?,
      do: check(post, account),
      else: :ok
  end

  @doc "A narrow title input; never casts arbitrary platform options."
  def put_title(changeset, attrs, account) do
    case Map.fetch(attrs, :title) do
      :error -> put_title_value(changeset, Map.fetch(attrs, "title"), account)
      found -> put_title_value(changeset, found, account)
    end
  end

  defp put_title_value(changeset, :error, _account), do: changeset

  defp put_title_value(changeset, {:ok, title}, %Account{platform: "youtube"})
       when is_binary(title) or is_nil(title) do
    case PlatformOptions.validate("youtube", %{"title" => title}) do
      {:ok, opts} ->
        existing = Changeset.get_field(changeset, :platform_options) || %{}

        Changeset.put_change(
          changeset,
          :platform_options,
          Map.merge(Map.delete(existing, "title"), opts)
        )

      {:error, errors} ->
        Changeset.add_error(changeset, :title, errors["title"])
    end
  end

  defp put_title_value(changeset, {:ok, _}, %Account{platform: "youtube"}),
    do: Changeset.add_error(changeset, :title, "must be a title string")

  defp put_title_value(changeset, {:ok, _}, _), do: changeset

  defp title_errors(post, %Account{platform: "youtube"}) do
    title = (post.platform_options || %{})["title"]

    cond do
      not is_binary(title) or String.trim(title) == "" ->
        ["Add a video title (YouTube needs one, up to 100 characters)."]

      String.length(title) > 100 ->
        ["Video title must be at most 100 characters."]

      true ->
        []
    end
  end

  defp title_errors(_, _), do: []

  defp text_errors(post, account) do
    body = post.body || ""
    limits = PlatformLimits.get(account.platform)
    count = PlatformLimits.count(account.platform, body)

    cond do
      String.trim(body) == "" ->
        ["Add the post text."]

      is_nil(limits) ->
        ["This platform is not supported."]

      count > limits.max_body ->
        ["Shorten the text: #{count} of #{limits.max_body} characters for #{limits.label}."]

      true ->
        []
    end
  end

  defp time_errors(%{scheduled_at: nil}, _), do: ["Choose a publish time."]

  defp time_errors(%{scheduled_at: %DateTime{} = at}, now) do
    if DateTime.compare(at, now) == :gt,
      do: [],
      else: ["The publish time has passed. Choose a new one."]
  end

  defp time_errors(_, _), do: ["Choose a publish time."]

  defp cover_errors(%{cover_file_id: nil, cover_offset_ms: nil}), do: []

  defp cover_errors(post) do
    changeset =
      post
      |> Changeset.change()
      |> Changeset.force_change(:media_file_ids, post.media_file_ids || [])
      |> Platform.Social.Cover.validate(%{})

    Enum.map(changeset.errors, fn {_field, {message, _}} -> message end)
  end

  defp option_errors(post, account) do
    case PlatformOptions.validate(account.platform, post.platform_options || %{}) do
      {:ok, _} -> []
      {:error, errors} -> errors |> Map.delete("title") |> Enum.sort() |> Enum.map(&elem(&1, 1))
    end
  end

  defp account_errors(account) do
    cond do
      account.approval_mode == "draft_only" ->
        ["This account is draft-only; it does not publish."]

      account.archived_at != nil or account.status != "connected" ->
        ["Reconnect the account."]

      true ->
        []
    end
  end

  defp media_errors(post, account) do
    ids = post.media_file_ids || []

    org_id =
      case Platform.Repo.get(Platform.Social.Profile, account.profile_id) do
        nil -> nil
        profile -> profile.org_id
      end

    files = Enum.map(ids, &Platform.Files.get_file/1)

    cond do
      Enum.any?(files, &(is_nil(&1) or not OrgFiles.in_org?(&1, org_id))) ->
        ["A media file is missing or not in this org"]

      Enum.any?(files, &(not Platform.Files.finalized_upload?(&1))) ->
        ["Finish uploading the media before review."]

      ids == [] and account.platform == "instagram" ->
        ["Add a video or an image."]

      ids == [] and account.platform in ["youtube", "tiktok"] ->
        ["Add a video."]

      true ->
        media =
          Enum.zip_with(ids, files, fn id, file ->
            facts = (post.media_meta || %{})[id] || %{}

            %{
              content_type: file.content_type,
              byte_size: file.byte_size,
              duration_s: facts["duration_s"],
              width: facts["width"],
              height: facts["height"]
            }
          end)

        case MediaRules.check(account.platform, account, media) do
          :ok -> []
          {:error, messages} -> messages
        end
    end
  end
end
