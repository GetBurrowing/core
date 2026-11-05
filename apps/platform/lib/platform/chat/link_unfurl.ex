defmodule Platform.Chat.LinkUnfurl do
  @moduledoc """
  One stored preview of an outside link (task 01a1a944 stage 2), keyed by
  the link's normalised URL (`Platform.Chat.LinkUnfurls.normalize/1`), so
  every message that posts the same page shares one row and one fetch.

  `status`:

    * `pending`: a fetch is in flight (short expiry, so a crashed fetch is
      retried);
    * `ok`: fetched and at least a title, description or image was found;
      expires after 7 days;
    * `failed`: the fetch or parse came back empty or errored; expires after
      1 hour (a negative cache);
    * `refused`: the SSRF guard refused the URL or a redirect hop; nothing
      was fetched past the refusal. Expires after 1 hour.

  `media_kind` is `video`, `article` or `other`. Image dimensions are stored
  as the provider or page states them, never derived.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @statuses ~w(pending ok failed refused)
  @media_kinds ~w(video article other)

  @fields ~w(url_key url status title description image_url image_width image_height
             site_name author provider media_kind duration_seconds fetched_at expires_at)a

  @type t :: %__MODULE__{}

  schema "link_unfurls" do
    field(:url_key, :string)
    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:title, :string)
    field(:description, :string)
    field(:image_url, :string)
    field(:image_width, :integer)
    field(:image_height, :integer)
    field(:site_name, :string)
    field(:author, :string)
    field(:provider, :string)
    field(:media_kind, :string)
    field(:duration_seconds, :integer)
    field(:fetched_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses a row can carry."
  def statuses, do: @statuses

  @doc false
  def changeset(unfurl, attrs) do
    unfurl
    |> cast(attrs, @fields)
    |> validate_required([:url_key, :url, :status, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:media_kind, @media_kinds)
    |> unique_constraint(:url_key)
  end
end
