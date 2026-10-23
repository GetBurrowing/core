defmodule Platform.Social.Publisher do
  @moduledoc """
  The vendor-independent publishing contract (task 01a140a9, Social 2/7).

  The vendor is Zernio (self-hosted Postiz is plan B), but nothing in Social
  knows which one it talks to except the adapter module and ONE config key:

      config :social, :publisher, Platform.Social.Publisher.Fake

  `impl/0` reads that key on every call. dev and test select
  `Platform.Social.Publisher.Fake` (`apps/social/config/config.exs`). prod
  selects through the `SOCIAL_PUBLISHER` env var, which
  `Platform.Social.RuntimeConfig` reads at boot in
  `Platform.Social.Application.start/2`: `SOCIAL_PUBLISHER=zernio` selects
  `Platform.Social.Publisher.Zernio`. With it unset, `impl/0` answers
  `{:error, :publisher_not_configured}` and nothing publishes.

  ## Profiles and platforms

  `ensure_profile/1` makes sure the vendor holds a profile for one of ours
  before `connect_url/2` runs, and answers its id (the caller stores it as
  `provider_profile_ref`). An adapter that needs no vendor-side profile
  answers `:not_required` and never calls out (the Fake does, and invents no
  ref). `platforms/0` lists the platforms the adapter can connect, in our
  names (`Platform.Social.Account.platforms/0`).

  `list_accounts/1` reads the vendor's own list of accounts connected under
  one of our profiles, fetched with our key (task 01a14807). It is the ONLY
  authority for marking an account connected: an OAuth return's URL params
  are never trusted on their own. Each entry's `ref` is the vendor's account
  id, verbatim, which is exactly what `publish/2` later sends as the account
  id, so the caller stores it as `provider_account_ref`. `platform` is in our
  names, and entries on a platform we do not support are dropped. An adapter
  with no vendor-side profile answers `{:ok, []}` and never calls out (the
  Fake does, and invents no ids). The caller still re-checks each entry's
  `profile_ref` against the profile it asked about.

  `disconnect_account/1` disconnects one of our accounts at the vendor
  (task 01a14ac6), by its `provider_account_ref`. An account with no ref was
  never connected there: `{:error, :not_connected}` and no request is sent.
  A vendor that answers "already disconnected" counts as `:ok`, so the call is
  idempotent. It touches no row: archiving ours is the caller's job, and only
  a human approver may ask for it. The Fake answers `:ok` with no network.

  ## Secrets

  An adapter never reads a key from config, env, the DB or a struct field.
  The account's API key and each profile's webhook secret live in the Vault
  and are read with `Platform.Social.Secrets` (the `Platform.Mail` accessor
  pattern). A missing secret fails closed.

  ## The publish guard

  `publish/2` is called from exactly ONE place, `Platform.Social.Publishing.publish_post/2`,
  which re-reads the post under a row lock and refuses unless it is
  `approved` with a human approver. A test pins the single call site.
  """

  @typedoc "A post's media, vendor-neutral. `duration_s` is `nil` for images or when unknown."
  @type media :: %{
          url: String.t(),
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          duration_s: number() | nil
        }

  @typedoc """
  A video post's cover (task 01a165ec, stage 3): an uploaded image, by a
  vendor-fetchable signed URL, or a frame of the video, by offset. `nil`
  when the post has none. An adapter maps it where its platform takes a
  cover at create time and ignores it elsewhere.
  """
  @type cover ::
          nil
          | %{kind: :image, url: String.t(), content_type: String.t()}
          | %{kind: :frame, offset_ms: non_neg_integer()}

  @typedoc """
  The vendor-neutral publish request. `idempotency_key` is the post id, so a
  retried publish is a replay at the vendor, not a second post.
  """
  @type request :: %{
          body: String.t() | nil,
          link_url: String.t() | nil,
          scheduled_at: DateTime.t() | nil,
          media: [media()],
          is_aigc: boolean(),
          ai_disclosure: String.t() | nil,
          platform: String.t(),
          idempotency_key: String.t(),
          cover: cover()
        }

  @type publish_result :: %{
          external_id: binary(),
          status: :scheduled | :published,
          external_url: binary() | nil
        }

  @type status_result :: %{
          status: :scheduled | :published | :failed,
          external_url: binary() | nil,
          error: String.t() | nil
        }

  @typedoc "One status event from a verified webhook delivery."
  @type event :: %{
          event_id: String.t() | nil,
          external_id: String.t() | nil,
          kind: :published | :failed | :ignored,
          external_url: String.t() | nil,
          error: String.t() | nil
        }

  @type delivery :: %{raw_body: binary(), headers: map()}

  @type account :: Platform.Social.Account.t()

  @typedoc """
  One account the vendor lists under a profile. `ref` is the vendor's account
  id (stored verbatim as `provider_account_ref`); `platform` is in our names;
  `profile_ref` is the vendor profile id the entry says it belongs to.
  `account_type` is the platform's account kind when the vendor documents one
  (a value in `Platform.Social.Account.platform_account_types/0`), else nil.
  An entry without the key reads as nil.
  """
  @type connected_account :: %{
          ref: String.t(),
          platform: String.t(),
          profile_ref: String.t() | nil,
          username: String.t() | nil,
          active?: boolean(),
          account_type: String.t() | nil
        }

  @doc "Starts OAuth for `account`. `opts` carries `:redirect_url` (and `:profile`)."
  @callback connect_url(account(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Makes sure the vendor has a profile for `profile`. `{:ok, ref}` is the
  vendor's profile id (an existing `provider_profile_ref` is answered as-is,
  with no request); `:not_required` means the adapter needs none.
  """
  @callback ensure_profile(Platform.Social.Profile.t()) ::
              {:ok, String.t()} | :not_required | {:error, term()}

  @doc """
  The accounts the vendor lists under `profile`, read with our key. A
  profile with no vendor ref is `{:error, :profile_not_linked}` and no request
  is sent.
  """
  @callback list_accounts(Platform.Social.Profile.t()) ::
              {:ok, [connected_account()]} | {:error, term()}

  @doc "The platforms this adapter can connect, in our names."
  @callback platforms() :: [String.t()]

  @doc "Creates (or schedules) the post at the vendor."
  @callback publish(account(), request()) :: {:ok, publish_result()} | {:error, term()}

  @doc "Reads a post's state at the vendor."
  @callback status(account(), external_id :: String.t()) ::
              {:ok, status_result()} | {:error, term()}

  @doc "Deletes (cancels) a post at the vendor."
  @callback delete(account(), external_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Disconnects `account` at the vendor. An account with a nil or blank
  `provider_account_ref` is `{:error, :not_connected}` and no request is sent;
  one the vendor already disconnected is `:ok`.
  """
  @callback disconnect_account(account()) :: :ok | {:error, term()}

  @doc """
  OPTIONAL. Sets an uploaded cover image on a post AFTER it is published,
  for platforms whose create call takes none (YouTube). `url` is a
  vendor-fetchable signed URL. Called once, never retried; a failure is
  recorded on the post's `cover_error` and never changes its status.
  """
  @callback set_cover(account(), external_id :: String.t(), url :: String.t()) ::
              :ok | {:error, term()}

  @optional_callbacks set_cover: 3

  @doc """
  Verifies a webhook delivery's signature over the RAW body with `secret`
  and normalizes it into events. Anything unverifiable is
  `{:error, :invalid_signature}`.
  """
  @callback verify_webhook(delivery(), secret :: binary()) ::
              {:ok, [event()]} | {:error, :invalid_signature}

  @doc """
  The configured adapter module, read from `config :social, :publisher` on
  every call, or `{:error, :publisher_not_configured}` when it is unset.
  """
  @spec impl() :: module() | {:error, :publisher_not_configured}
  def impl do
    case Application.get_env(:social, :publisher) do
      nil -> {:error, :publisher_not_configured}
      module when is_atom(module) -> module
    end
  end
end
