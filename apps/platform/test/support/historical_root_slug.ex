defmodule Platform.Tenancy.HistoricalRootSlug do
  @moduledoc """
  The original operator's root-org row, as applied migrations pin it.

  Migrations that already ran on every install pin rows for the original
  operator's root slug (for example the shipped colour pins of
  `20260921190000_add_color_lightness_to_orgs`). Since task 01a14b9e stage 5
  those migrations match that slug by its sha256 digest, so the row's key is
  `{:sha256, hex}` rather than the slug, and the tree carries no install
  identity. Tests call that row `legacy` where a readable label is needed.

  The root row is found structurally: it is the one shipped row whose key is
  a digest rather than a tenant slug.
  """

  @tenants ~w(soylent wayne_tech wayne-tech sxi paragon cyberdyne)

  @doc "The tenant slugs the shipped rows carry besides the root's."
  def tenants, do: @tenants

  @doc """
  The root key among `rows` (tuples whose first element is a key): the one
  key that is a `{:sha256, hex}` digest. Raises unless exactly one such key
  exists and every other key is a listed tenant slug.
  """
  def from_rows(rows) do
    keys = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    [{:sha256, hex} = root] = Enum.filter(keys, &match?({:sha256, _}, &1))
    true = Enum.all?(keys -- [root], &(&1 in @tenants))
    {:sha256, hex}
  end

  @doc "`rows` with the root key relabelled `\"legacy\"`."
  def relabel(rows) do
    root = from_rows(rows)

    Enum.map(rows, fn row ->
      if elem(row, 0) == root, do: put_elem(row, 0, "legacy"), else: row
    end)
  end
end
