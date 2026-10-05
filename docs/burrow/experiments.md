---
title: Experiments
summary: Testing alternatives at a decision point - surfaces, variants, assignments, results.
order: 11
verified_at: "837fba6e"
---

# Experiments

## What it is

An experiment tries two or more alternatives at one decision point in Burrow and measures which works better. It might compare two wordings of the prompt agents are dispatched with, or two planning budgets. Burrow keeps every experiment, running or finished, on the Experiments page (`/control/experiments`).

### Surfaces

A **surface** is a decision point that experiments can vary. Each one is declared once in the product's code, with:

- a key, such as `dispatch.prompt`;
- the kind of subject it decides for (today, a task);
- the shape of the payload each alternative carries;
- its **control**, the behaviour Burrow uses when no experiment says otherwise.

Burrow's surfaces cover the dispatch prompt, the planner's stage budget, chat context summaries, mail draft generation and the classification of open questions in meetings. Optional modules can add their own.

### Variants

Each alternative is a **variant**, also called an arm. You add treatment arms while the experiment is a draft. The control arm is captured when the experiment starts, as a snapshot of the current behaviour, so later edits to the live setting cannot change what the experiment compares against.

### Assignments

Once an experiment is running, each new subject that reaches the surface is assigned to one arm, by weight, and keeps it for good. A task assigned an arm at planning gets the same arm at execution. An experiment can be scoped to one project or one org, and can carry a policy that decides which subjects take part. A subject removed from the analysis keeps its row, marked excluded, with the reason.

### Results and promotion

Outcome signals are labelled and matched to subjects. Each arm's result is shown with its sample size, and an arm has no figure at all until it has enough data to meet the experiment's stop rule. When an arm wins, **promotion** makes it the default for new subjects. Subjects already assigned keep their arm.

### Why an experiment is data, not a deploy

The surface is the only part that is code. Every experiment on it, with its arms, assignments and results, is rows in Burrow's database. Starting, stopping or promoting one changes no code and needs no release. That is what makes it cheap to try an idea, and safe to stop one that is not working.

## When to use it

- **You can see two reasonable ways to do something** at a point Burrow already exposes as a surface, and you want evidence rather than opinion.
- **A change you want to make is risky:** run it as an arm against the control before making it the default.
- **No surface exists for the decision:** an experiment cannot vary it. A surface has to be added to the product first.
- **The answer is obvious or the decision is rare:** just make the change. An experiment needs enough subjects to say anything.

## How agents use it

- `experiment_surface_list` lists the surfaces and the payload shape each arm must carry.
- `experiment_goal_set` and `experiment_goal_list` manage the standing goals experiments are proposed against.
- `experiment_create` creates a draft on a surface, with a hypothesis, metric, stop rule and optional scope. `experiment_variant_add` adds a treatment arm. The slug `control` is reserved.
- `experiment_start` launches a draft under the org's guardrails, which limit how many experiments run at once, which surfaces agents may use, and allow only one running experiment per surface and scope. If the org requires a person to approve launches, the experiment waits as pending approval. That is success, not an error to retry.
- `experiment_list` and `experiment_get` read experiments. `experiment_results` gives each arm's figure with its sample size. `experiment_signals_list` shows the labelled signals.
- `experiment_exclude` removes one subject from the analysis, with a reason.
- `experiment_stop` halts an experiment. `experiment_conclude` marks one that ran to its end. They are different outcomes, and both stay listed.
- `experiment_promote` promotes a winning arm, when the org's guardrails allow it and the arm has met its stop rule. Mail surfaces are never promoted this way, and a surface promoted recently is in a cooldown.

## Common mistakes

- **Reading a figure without its sample size.** Every result travels with its n. An arm with too little data shows no figure, not zero.
- **Stopping when you mean concluding.** Stopped means halted early. Concluded means it ran to its end and was decided.
- **Editing the live setting during an experiment and expecting the control to follow.** The control is the snapshot taken at start.
- **Retrying a launch that is pending approval.** It is waiting for a person, not failing.

_Last verified at 837fba6e._
