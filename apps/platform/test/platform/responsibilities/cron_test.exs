defmodule Platform.Responsibilities.CronTest do
  @moduledoc """
  Focused unit tests for `Platform.Responsibilities.Cron` — the pure
  parser + minute-walk scheduler that backs Router cron dispatch.

  The bulk of the parse/next-fire coverage lives inline in
  `Platform.Responsibilities.RouterTest` (M6 stage 2). This module
  covers behaviour that RouterTest doesn't exercise: the optional
  `:timezone` opt added in task 019f70e9 stage 6, which shifts
  match-evaluation into a named IANA zone so the returned UTC fire
  time is correct on both sides of DST.
  """
  use ExUnit.Case, async: true

  alias Platform.Responsibilities.Cron

  describe "next_fire_after/3 with :timezone option" do
    # The Router configures Handlers.Dreaming with
    #   %{"expression" => "0 3 * * *", "timezone" => "America/Chicago"}
    # so `0 3 * * *` must resolve to 03:00 America/Chicago year-round
    # — 08:00 UTC in summer (CDT, UTC-5) and 09:00 UTC in winter
    # (CST, UTC-6). Both assertions run in the same test so a broken
    # timezone shift can't accidentally pass one but fail the other.

    test "0 3 * * * in America/Chicago fires at 08:00 UTC in July (CDT)" do
      # July 15 2026 at 00:00 UTC is safely before 03:00 America/Chicago
      # that same date (which is 08:00 UTC on 2026-07-15).
      {:ok, spec} = Cron.parse("0 3 * * *")
      now_utc = ~U[2026-07-15 00:00:00Z]

      assert {:ok, %DateTime{} = next} =
               Cron.next_fire_after(now_utc, spec, timezone: "America/Chicago")

      assert next.time_zone == "Etc/UTC"
      assert next.year == 2026
      assert next.month == 7
      assert next.day == 15
      assert next.hour == 8
      assert next.minute == 0

      # Sanity-check the zone shift: when we shift the returned UTC
      # dt into America/Chicago it must land on the 03:00 anchor.
      chicago = DateTime.shift_zone!(next, "America/Chicago")
      assert chicago.hour == 3
      assert chicago.minute == 0
    end

    test "0 3 * * * in America/Chicago fires at 09:00 UTC in January (CST)" do
      # January 15 2026 — well outside any DST transition window;
      # America/Chicago is CST (UTC-6) so 03:00 local == 09:00 UTC.
      {:ok, spec} = Cron.parse("0 3 * * *")
      now_utc = ~U[2026-01-15 00:00:00Z]

      assert {:ok, %DateTime{} = next} =
               Cron.next_fire_after(now_utc, spec, timezone: "America/Chicago")

      assert next.time_zone == "Etc/UTC"
      assert next.year == 2026
      assert next.month == 1
      assert next.day == 15
      assert next.hour == 9
      assert next.minute == 0

      chicago = DateTime.shift_zone!(next, "America/Chicago")
      assert chicago.hour == 3
      assert chicago.minute == 0
    end

    test "nil / omitted timezone preserves pre-timezone UTC behaviour" do
      {:ok, spec} = Cron.parse("0 3 * * *")
      now_utc = ~U[2026-07-15 00:00:00Z]

      # No opts.
      assert {:ok, next_a} = Cron.next_fire_after(now_utc, spec)
      # Explicit nil.
      assert {:ok, next_b} = Cron.next_fire_after(now_utc, spec, timezone: nil)
      # Explicit UTC aliases.
      assert {:ok, next_c} = Cron.next_fire_after(now_utc, spec, timezone: "UTC")
      assert {:ok, next_d} = Cron.next_fire_after(now_utc, spec, timezone: "Etc/UTC")

      assert next_a.hour == 3
      assert next_a == next_b
      assert next_a == next_c
      assert next_a == next_d
    end

    test "when 'now' is already past 03:00 America/Chicago, next fire rolls to tomorrow" do
      # 10:00 UTC on July 15 == 05:00 America/Chicago (CDT). 03:00
      # today has already passed, so we roll to 03:00 tomorrow
      # (2026-07-16 08:00 UTC).
      {:ok, spec} = Cron.parse("0 3 * * *")
      now_utc = ~U[2026-07-15 10:00:00Z]

      assert {:ok, next} =
               Cron.next_fire_after(now_utc, spec, timezone: "America/Chicago")

      assert next.year == 2026
      assert next.month == 7
      assert next.day == 16
      assert next.hour == 8
      assert next.minute == 0
    end

    test "day-of-month predicate is evaluated in the target zone, not UTC" do
      # 2026-07-01 04:00 UTC == 2026-06-30 23:00 America/Chicago. The
      # spec `0 3 1 * *` (03:00 on the 1st) must fire based on the
      # local calendar — the next matching local time is 2026-07-01
      # 03:00 CDT == 2026-07-01 08:00 UTC (~4 hours away). If we
      # accidentally evaluated in UTC we'd fire on 2026-08-01 instead.
      {:ok, spec} = Cron.parse("0 3 1 * *")
      now_utc = ~U[2026-07-01 04:00:00Z]

      assert {:ok, next} =
               Cron.next_fire_after(now_utc, spec, timezone: "America/Chicago")

      chicago = DateTime.shift_zone!(next, "America/Chicago")
      assert chicago.year == 2026
      assert chicago.month == 7
      assert chicago.day == 1
      assert chicago.hour == 3
      assert chicago.minute == 0
    end
  end

  describe "next_fire_after/3 — memory.dreaming 05:00 America/Chicago (task 019f905e)" do
    # Handlers.Dreaming moved 03:00 → 05:00 America/Chicago. The fire
    # time must stay pinned to 05:00 *local* on both sides of the DST
    # boundary (not a fixed UTC hour): 10:00 UTC in summer (CDT, UTC-5)
    # and 11:00 UTC in winter (CST, UTC-6). Both assertions in one test
    # so a broken zone shift can't pass one and fail the other.

    test "0 5 * * * in America/Chicago fires at 10:00 UTC in July (CDT)" do
      # July 15 2026 at 00:00 UTC is safely before 05:00 America/Chicago
      # that same date (which is 10:00 UTC on 2026-07-15).
      {:ok, spec} = Cron.parse("0 5 * * *")
      now_utc = ~U[2026-07-15 00:00:00Z]

      assert {:ok, %DateTime{} = next} =
               Cron.next_fire_after(now_utc, spec, timezone: "America/Chicago")

      assert next.time_zone == "Etc/UTC"
      assert next.year == 2026
      assert next.month == 7
      assert next.day == 15
      assert next.hour == 10
      assert next.minute == 0

      chicago = DateTime.shift_zone!(next, "America/Chicago")
      assert chicago.hour == 5
      assert chicago.minute == 0
    end

    test "0 5 * * * in America/Chicago fires at 11:00 UTC in January (CST)" do
      # January 15 2026 — well outside any DST transition window;
      # America/Chicago is CST (UTC-6) so 05:00 local == 11:00 UTC.
      {:ok, spec} = Cron.parse("0 5 * * *")
      now_utc = ~U[2026-01-15 00:00:00Z]

      assert {:ok, %DateTime{} = next} =
               Cron.next_fire_after(now_utc, spec, timezone: "America/Chicago")

      assert next.time_zone == "Etc/UTC"
      assert next.year == 2026
      assert next.month == 1
      assert next.day == 15
      assert next.hour == 11
      assert next.minute == 0

      chicago = DateTime.shift_zone!(next, "America/Chicago")
      assert chicago.hour == 5
      assert chicago.minute == 0
    end
  end
end
