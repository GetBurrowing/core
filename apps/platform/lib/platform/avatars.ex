defmodule Platform.Avatars do
  @moduledoc """
  The rules a human's letter-disc avatar is drawn by, in the Platform layer so
  every renderer reads the same ones (task 01a12773 stage 2).

  `PlatformWeb.AvatarComponents` draws the disc in the browser, and the push
  notification carries `fallback_tone/1` as `author_avatar_tone` so the
  native apps draw the same colour when they have no picture. Both call into
  this module rather than each computing an index, so web and push cannot
  drift (design canvas "one avatar renderer"). Platform never calls
  PlatformWeb, so the shared rules live here and the component calls down.
  """

  @palette_size 8

  @doc "How many fallback colours the palette has (`avatar-fallback-0..7` in app.css)."
  @spec palette_size() :: pos_integer()
  def palette_size, do: @palette_size

  @doc """
  The fallback palette index, `0..7`, for an avatar seed. Any term is
  accepted and stringified first, exactly as the chat renders it, so an
  integer seed and its string form get the same colour.
  """
  @spec fallback_tone(term()) :: non_neg_integer()
  def fallback_tone(seed), do: :erlang.phash2(to_string(seed), @palette_size)

  @doc """
  The seed a human chat participant's disc is coloured by: the user's
  `oidc_sub`, else their email, else the participant's `participant_id`,
  else its row id, else `"user"`.

  `PlatformWeb.ChatLive.PresenceHooks` builds a participant's
  `avatar_seed` with this, and the push notification computes its tone from
  it, so a person is the same colour in chat and on the lock screen.
  """
  @spec user_seed(map(), map() | nil) :: String.t()
  def user_seed(participant, user) do
    cond do
      present?(user && Map.get(user, :oidc_sub)) -> user.oidc_sub
      present?(user && Map.get(user, :email)) -> user.email
      present?(Map.get(participant, :participant_id)) -> participant.participant_id
      present?(Map.get(participant, :id)) -> participant.id
      true -> "user"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
