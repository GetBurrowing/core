defmodule Platform.Social.Cover do
  @moduledoc """
  A video post's cover (task 01a165ec, stage 2): EITHER an uploaded image
  (`cover_file_id`) OR a frame of the video (`cover_offset_ms`).

  `validate/3` is the ONE cover rule. `Platform.Social.Post.changeset/2`,
  `Platform.Social.Post.cover_changeset/3` (the human path,
  `Platform.Social.set_cover/4`) and `Platform.Social.AgentDrafts` (the
  agent path) all call it, so the refusals read the same everywhere:

    * one cover at a time: setting one field clears the other, both
      non-nil in one call is refused, both nil clears the cover;
    * only on a post whose media holds a video (`video/*`);
    * `cover_file_id` exists in the post's org (`Platform.Social.OrgFiles`)
      and is a JPG or PNG;
    * `cover_offset_ms` is an integer from 0 to the video's duration, read
      from `media_meta[video_id]["duration_s"]` (or a rendered clip's facts,
      `Platform.Social.ClipMedia`); an unknown duration is refused;
    * a cover change on a post past `needs_approval` is refused with
      reason `:post_locked`.

  The org/profile context is passed by callers that hold it, else resolved
  from the post's account, and only when there is a cover to check.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.{Account, ClipMedia, OrgFiles, Profile}

  @fields [:cover_file_id, :cover_offset_ms]
  @image_types ~w(image/jpeg image/png)
  @editable_statuses ~w(draft needs_approval)

  @both "choose either an uploaded cover or a frame, not both"
  @not_video "a cover applies only to a video post"
  @not_image "cover must be a JPG or PNG image"
  @not_in_org "cover must exist in the profile's org"
  @unknown_duration "the video's duration is unknown, so a frame cannot be checked"

  @type ctx :: %{org_id: Ecto.UUID.t() | nil, profile_id: Ecto.UUID.t() | nil} | nil

  @doc "The content types an uploaded cover may have (JPG, PNG)."
  @spec image_types() :: [String.t()]
  def image_types, do: @image_types

  @doc "The refusal for a cover that is not a JPG or PNG (the picker's upload check reuses it)."
  @spec not_image_message() :: String.t()
  def not_image_message, do: @not_image

  @doc "The two cover fields an editor may set."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  Applies the one-cover rule and validates the cover on a changeset that
  has already cast `attrs` (`attrs` is read only to see whether both fields
  were sent). `ctx` is `%{org_id, profile_id}`, or nil to resolve it from
  the changeset's `account_id`.
  """
  @spec validate(Ecto.Changeset.t(), map(), ctx()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = changeset, attrs, ctx \\ nil) do
    changeset = one_at_a_time(changeset, attrs)
    cover_changed? = Enum.any?(@fields, &Map.has_key?(changeset.changes, &1))
    media_changed? = Map.has_key?(changeset.changes, :media_file_ids)
    file_id = get_field(changeset, :cover_file_id)
    offset = get_field(changeset, :cover_offset_ms)

    cond do
      Enum.any?(changeset.errors, fn {field, _} -> field in @fields end) ->
        changeset

      not cover_changed? and not media_changed? ->
        changeset

      cover_changed? and changeset.data.status not in @editable_statuses ->
        add_error(changeset, cover_field(file_id), "post is locked", reason: :post_locked)

      is_nil(file_id) and is_nil(offset) ->
        changeset

      true ->
        ctx = ctx || resolve_ctx(changeset)
        check_cover(changeset, file_id, offset, ctx)
    end
  end

  @doc """
  The human path's duration backfill (stage 4): when a frame is chosen and
  neither `media_meta` nor a rendered clip knows the video's duration, the
  browser's `<video>.duration` (`duration_ms`) is stored as
  `media_meta[video_id]["duration_s"]`. A known duration is never
  overwritten.
  """
  @spec backfill_duration(Ecto.Changeset.t(), term(), ctx()) :: Ecto.Changeset.t()
  def backfill_duration(changeset, duration_ms, ctx \\ nil)

  def backfill_duration(changeset, duration_ms, ctx)
      when is_integer(duration_ms) and duration_ms > 0 do
    with offset when not is_nil(offset) <- get_change(changeset, :cover_offset_ms),
         %{id: video_id} <- video(changeset),
         ctx = ctx || resolve_ctx(changeset),
         nil <- duration_s(changeset, video_id, ctx) do
      meta = get_field(changeset, :media_meta) || %{}
      facts = Map.get(meta, video_id) || %{}

      put_change(
        changeset,
        :media_meta,
        Map.put(meta, video_id, Map.put(facts, "duration_s", duration_ms / 1000))
      )
    else
      _ -> changeset
    end
  end

  def backfill_duration(changeset, _duration_ms, _ctx), do: changeset

  # ── Rules ────────────────────────────────────────────────────────────

  defp one_at_a_time(changeset, attrs) do
    file_given = attr(attrs, :cover_file_id)
    offset_given = attr(attrs, :cover_offset_ms)

    cond do
      not is_nil(file_given) and not is_nil(offset_given) ->
        add_error(changeset, :cover_file_id, @both)

      not is_nil(get_change(changeset, :cover_file_id)) ->
        put_change(changeset, :cover_offset_ms, nil)

      not is_nil(get_change(changeset, :cover_offset_ms)) ->
        put_change(changeset, :cover_file_id, nil)

      true ->
        changeset
    end
  end

  defp check_cover(changeset, file_id, offset, ctx) do
    case video(changeset) do
      nil -> add_error(changeset, cover_field(file_id), @not_video)
      _video when is_binary(file_id) -> check_file(changeset, file_id, ctx)
      video -> check_offset(changeset, offset, video, ctx)
    end
  end

  defp check_file(changeset, file_id, ctx) do
    file = Platform.Files.get_file(file_id)

    cond do
      is_nil(file) or not OrgFiles.in_org?(file, ctx.org_id) ->
        add_error(changeset, :cover_file_id, @not_in_org)

      file.content_type not in @image_types ->
        add_error(changeset, :cover_file_id, @not_image)

      true ->
        changeset
    end
  end

  defp check_offset(changeset, offset, video, ctx) do
    if offset < 0 do
      validate_number(changeset, :cover_offset_ms, greater_than_or_equal_to: 0)
    else
      case duration_s(changeset, video.id, ctx) do
        nil ->
          add_error(changeset, :cover_offset_ms, @unknown_duration)

        duration_s when offset <= round(duration_s * 1000) ->
          changeset

        duration_s ->
          add_error(
            changeset,
            :cover_offset_ms,
            "cover frame is past the end of the video (#{clock(duration_s)})"
          )
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # The first video in the post's media, through core's Files.
  defp video(changeset) do
    (get_field(changeset, :media_file_ids) || [])
    |> Enum.find_value(fn id ->
      case Platform.Files.get_file(id) do
        %{content_type: "video/" <> _} = file -> file
        _ -> nil
      end
    end)
  end

  # media_meta, with a rendered clip's facts merged over it exactly as
  # `ClipMedia.put_media_meta/2` will at write time.
  defp duration_s(changeset, video_id, ctx) do
    stored = get_field(changeset, :media_meta) || %{}
    clip = ClipMedia.meta_for(ctx && ctx.profile_id, [video_id])

    case Map.merge(stored, clip) |> Map.get(video_id) do
      %{"duration_s" => d} when is_number(d) and d > 0 -> d
      _ -> nil
    end
  end

  defp resolve_ctx(changeset) do
    case get_field(changeset, :account_id) do
      nil ->
        %{org_id: nil, profile_id: nil}

      account_id ->
        Repo.one(
          from(a in Account,
            join: p in Profile,
            on: p.id == a.profile_id,
            where: a.id == ^account_id,
            select: %{org_id: p.org_id, profile_id: p.id}
          )
        ) || %{org_id: nil, profile_id: nil}
    end
  end

  defp cover_field(file_id) when is_binary(file_id), do: :cover_file_id
  defp cover_field(_), do: :cover_offset_ms

  defp attr(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp attr(_attrs, _key), do: nil

  defp clock(duration_s) do
    total = trunc(duration_s)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
