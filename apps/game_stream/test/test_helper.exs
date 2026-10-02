# Play's tests run on core's test harness, unchanged: the same ExUnit
# exclusions, sandbox mode, org seeding and module preload core's own
# `mix test` runs (ADR 0055, task 01a0ee08 stage 3). Required, not copied, so
# the two cannot drift.
Code.require_file("../../platform/test/test_helper.exs", __DIR__)
