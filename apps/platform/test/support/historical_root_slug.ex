defmodule Platform.Tenancy.HistoricalRootSlug do
  @moduledoc """
  The shipped org rows that applied migrations pin, keyed by digest.

  Migrations that already ran on every install pin rows for the original
  operator's root slug and for the shipped tenant slugs (for example the
  colour pins of `20260921190000_add_color_lightness_to_orgs`). Those
  migrations match each slug by its sha256 digest (the root since task
  01a14b9e stage 5, the tenants since task 01a14dd9 stage 3), so a row's key
  is `{:sha256, hex}` rather than the slug, and the tree carries no install
  identity.

  This module holds one record per digest key,
  `{slug_digest, placeholder_slug, term_digests}`:

    * `slug_digest` is the sha256 of the slug as the row stores it;
    * `placeholder_slug` is the readable name tests use for that row. The
      root is `legacy`; the tenants take the placeholder slugs the test
      fixtures use;
    * `term_digests` are the sha256 digests of the lowercase terms that
      identify that org (for a tenant: its slug, or the second part of an
      underscored slug; for the client org also its full name, its product
      and its contact). The install-identity guard is expected to list every
      one of them.

  No preimage is held here.
  """

  @records [
    {"9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c", "legacy",
     ["9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c"]},
    {"1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b", "initech",
     ["1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b"]},
    {"6033c506fee05cd2e9291a63854efcd0357866cb82dd5b6fceac7916f74cfdb3", "vandelay_ind",
     ["a4914116477206d6766723e306a2fe39e4b97c3cabfce141310622adbb33d34e"]},
    {"f80cf60200f6c7c32e92dae3c84a45a76d7cc8468ddb679983582805ac8d4a4b", "vandelay-ind",
     ["a4914116477206d6766723e306a2fe39e4b97c3cabfce141310622adbb33d34e"]},
    {"3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d", "globex",
     [
       "3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d",
       "fb3a3f5343ca1ff87236fb75ad0f48987d0fd0f4d15b787fb59057e37186f2a0",
       "4de7d59fd6866c46855c913fe9c7e498228200fdfcbb326f80062bdde43f4b51",
       "17d93b3e93059e01484fabea3489be14fc463ea0998b183a3360489e812fbf2c"
     ]},
    {"d0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c", "hooli",
     ["d0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c"]},
    {"71ce8a1658507fc4e432cb3621322632972d9256e652b1dee92af6528719216f", "wonka",
     ["71ce8a1658507fc4e432cb3621322632972d9256e652b1dee92af6528719216f"]}
  ]

  @doc "Every `{slug_digest, placeholder_slug, term_digests}` record."
  def records, do: @records

  @doc "The placeholder slugs of the tenant records (every record but the root)."
  def tenants, do: for({_d, slug, _t} <- @records, slug != "legacy", do: slug)

  @doc "Every term digest across the records, without duplicates."
  def term_digests, do: @records |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()

  @doc "The `{:sha256, hex}` key of the record whose placeholder is `slug`."
  def key(slug) when is_binary(slug) do
    {hex, ^slug, _} = List.keyfind(@records, slug, 1)
    {:sha256, hex}
  end

  @doc """
  The root key among `rows` (tuples whose first element is a key): the
  `{:sha256, hex}` key of the `legacy` record. Raises unless exactly that
  one root key is present and every key is a record's digest key.
  """
  def from_rows(rows) do
    keys = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    root = key("legacy")
    true = root in keys
    true = Enum.all?(keys, &(placeholder(&1) != nil))
    root
  end

  @doc """
  `rows` with every digest key replaced by its record's placeholder slug.
  Raises on a digest key no record carries; a key that is already a binary
  slug is kept.
  """
  def relabel(rows) do
    Enum.map(rows, fn row ->
      case elem(row, 0) do
        {:sha256, _} = key ->
          slug = placeholder(key) || raise ArgumentError, "no record for #{inspect(key)}"
          put_elem(row, 0, slug)

        _slug ->
          row
      end
    end)
  end

  defp placeholder({:sha256, hex}) do
    case List.keyfind(@records, hex, 0) do
      {^hex, slug, _} -> slug
      nil -> nil
    end
  end

  defp placeholder(_), do: nil
end
