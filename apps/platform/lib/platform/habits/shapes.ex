defmodule Platform.Habits.Shapes do
  @moduledoc """
  The cross-install SHAPE CONTRACT for learned defaults
  (`0061-learned-defaults.md` § 9, "Shape contract"). Task 01a1b6a1 stage 2.

  `aggregate/0` is the ONLY thing about learned defaults that may ever leave
  an install, and this module defines its shape only. It makes no network
  call and references no transport; transport is follow-on task 01a1b6a5,
  through the sharing registry entry `learned_default_shapes`.

  ## The keys, and nothing else

  Each element is a map with exactly these keys:

    * `action` — the registered action key, e.g. `"chat.message_attention"`.
    * `rung` — the pattern's ladder rung: `"rank" | "prefill" | "act"`.
    * `signal_count_bucket` — the pattern's stored signal count, bucketed:
      `"0-9" | "10-49" | "50+"`.
    * `accept_rate_bucket` — `accepted / (accepted + overridden)` over the
      pattern's signals, floored to tenths (`0.0, 0.1, ..., 1.0`), or `nil`
      when the pattern has no accepted or overridden signal.
    * `variant` — the `habits.learned_defaults` payload in force for the
      pattern's owner (four numbers, no ids).
    * `user_count` — the number of DISTINCT users whose patterns fall in the
      bucket `{action, rung, signal_count_bucket, accept_rate_bucket,
      variant}`.

  A bucket with fewer than 5 distinct users is suppressed (the k-anonymity
  floor). Users who have opted out of learning are excluded entirely. No
  user, space, target or message id, no name and no content appears.

  Resolving each owner's variant goes through `Platform.Habits.variant/1`,
  which may create an experiment assignment exactly as `suggest/3` would.
  """

  import Ecto.Query

  alias Platform.Habits
  alias Platform.Habits.Pattern
  alias Platform.Habits.Signal
  alias Platform.Repo

  @k_floor 5
  @keys [:action, :rung, :signal_count_bucket, :accept_rate_bucket, :variant, :user_count]

  @doc "The k-anonymity floor: buckets with fewer distinct users are dropped."
  @spec k_floor() :: pos_integer()
  def k_floor, do: @k_floor

  @doc "The exact key set of every `aggregate/0` element."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "See the moduledoc for the contract. Sorted for a stable encoding."
  @spec aggregate() :: [map()]
  def aggregate do
    counts =
      from(s in Signal,
        group_by: [s.actor_user_id, s.space_id, s.action, s.target_type, s.target_id],
        select: %{
          user_id: s.actor_user_id,
          space_id: s.space_id,
          action: s.action,
          target_type: s.target_type,
          target_id: s.target_id,
          total: count(s.id),
          accepted: filter(count(s.id), s.outcome == "accepted"),
          overridden: filter(count(s.id), s.outcome == "overridden")
        }
      )

    rows =
      from(p in Pattern,
        left_join: c in subquery(counts),
        on:
          c.user_id == p.user_id and c.action == p.action and
            c.target_type == p.target_type and c.target_id == p.target_id and
            fragment("? IS NOT DISTINCT FROM ?", c.space_id, p.space_id),
        select: %{
          user_id: p.user_id,
          action: p.action,
          rung: p.rung,
          total: coalesce(c.total, 0),
          accepted: coalesce(c.accepted, 0),
          overridden: coalesce(c.overridden, 0)
        }
      )
      |> Repo.all()

    variants =
      rows
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> Enum.filter(&Habits.enabled?/1)
      |> Map.new(&{&1, Habits.variant(&1)})

    rows
    |> Enum.filter(&Map.has_key?(variants, &1.user_id))
    |> Enum.group_by(
      fn row ->
        {row.action, row.rung, count_bucket(row.total), rate_bucket(row.accepted, row.overridden),
         Map.fetch!(variants, row.user_id)}
      end,
      & &1.user_id
    )
    |> Enum.map(fn {{action, rung, count_bucket, rate_bucket, variant}, user_ids} ->
      %{
        action: action,
        rung: rung,
        signal_count_bucket: count_bucket,
        accept_rate_bucket: rate_bucket,
        variant: variant,
        user_count: user_ids |> Enum.uniq() |> length()
      }
    end)
    |> Enum.filter(&(&1.user_count >= @k_floor))
    |> Enum.sort_by(&{&1.action, &1.rung, &1.signal_count_bucket, &1.accept_rate_bucket})
  end

  @doc false
  def count_bucket(n) when n < 10, do: "0-9"
  def count_bucket(n) when n < 50, do: "10-49"
  def count_bucket(_n), do: "50+"

  @doc false
  def rate_bucket(0, 0), do: nil
  # Integer arithmetic: `Float.floor(0.7, 1)` is 0.6.
  def rate_bucket(accepted, overridden),
    do: div(accepted * 10, accepted + overridden) / 10
end
