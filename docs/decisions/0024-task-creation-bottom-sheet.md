# ADR 0024: Task Creation Bottom Sheet & Validation Model

## Status

Draft — pending Rowan's approval

## Context

Burrow has a kanban board but no way to create tasks. The existing Tasky system proved that structured task → plan → execute → validate pipelines work. Burrow needs its own version, mobile-first, with tighter integration into the platform's chat, agents, and deploy infrastructure.

## Decision

### Task Creation — Bottom Sheet UI

Mobile-first bottom sheet triggered by a "+" FAB on the kanban. Also works on desktop as a slide-up panel.

#### Input Fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| **Title** | Single line text | Yes | Short imperative ("Add unread badges") |
| **What** | Auto-expanding textarea | Yes | What is being changed or added |
| **Why** | Auto-expanding textarea | Yes | Business/user justification for the change |
| **Epic** | Dropdown selector | No | Project epics |
| **Agent** | Dropdown selector | No | Defaults to principal, can override from roster |
| **Deploy Target** | Browser/selector | No | Driven by deploy configs. "None" is an option |
| **Validations** | Validation builder | No | See validation model below |
| **Attachments** | File upload | No | **Reuses the same upload module as chat** (LiveView `allow_upload`, `AttachmentStorage`) — no duplicate implementation |

**What vs Why separation**: Two distinct inputs in the UI. Humans and agents alike must provide both. They may be stored/passed as a single `description` field internally (concatenated with clear labels), but the input enforces both are filled.

#### Submit Actions

- **Create Task** — adds to backlog, no plan
- **Create & Request Plan** — creates task + fires `task.plan_requested` to the assigned agent

### Validation Model

Validations are first-class steps alongside plan stages. They define how the validator agent (or human) confirms the task was completed successfully.

#### Validation Input Modes (UI buttons, not schema types)

These are **UI-level controls** on the task creation form that tell the planning agent
what kind of validation strategy the user wants. They are NOT validation types in the
schema — the planner reads the selected mode and generates actual `Validation` records
using the existing mechanical types.

| Mode | UI | What it tells the planner |
|------|-----|--------------------------|
| **"Show me"** | Toggle/button | "Include at least one human-review step. I want to see a screenshot or demo before this ships." → Planner generates a `manual_approval` validation with instructions to produce visual proof. |
| **"Handle it"** | Toggle/button | "You figure out the right mechanical checks based on what's being done." → Planner auto-generates appropriate validations: `ci_check`, `lint_pass`, `type_check`, `test_pass`, `code_review` — whatever fits the task context. |
| **"Manual"** | Text input | "Here's a specific check I want." → User writes free-text criteria. Planner incorporates as a validation step (typically `manual_approval` or a custom check). |

These modes can be combined: user clicks "Handle it" AND "Show me" AND writes a manual
check → planner generates mechanical validations + a human review step + the custom check.

#### Existing Mechanical Validation Types (from ADR 0018)

These are the actual `validation_type` values in the `Validation` schema:

- `ci_check` — CI pipeline passes
- `lint_pass` — linter clean
- `type_check` — type checker passes
- `test_pass` — tests pass
- `code_review` — code review completed
- `manual_approval` — human reviews and approves (used for "show me" and custom checks)

The planner selects from these based on the validation input mode + task context.

#### Schema Changes

- Add `validation_mode` to task metadata (stores which input modes were selected: `["show_me", "handle_it"]`)
- Validations remain creatable at task creation time (manual mode) AND during plan generation (handle_it / show_me)
- Validations need approval flow parallel to plan stages

#### Approval Flow

```
Task Created (with validation mode selection)
  → Agent generates plan:
    - Plan stages (the How)
    - Proposed validations (based on validation mode + task context)
  → Human reviews plan stages → Approve / Request Revision
  → Human reviews proposed validations → Approve / Request Revision
  → Execution begins
  → Validation agent runs approved validation steps
  → "show_me" validations produce artifacts for human review
  → All validations pass → Task marked done
```

### Plan Review Panel (Task Detail)

Structured plan display with chat-based refinement:

- **Plan stages**: numbered list with status indicators
- **Validation steps**: separate section with type badges (show_me / handle_it / manual)
- **Chat**: inline conversation with the assigned agent to iterate on plan content
- **Actions**: Approve Plan, Approve Validations, Request Revision

The chat produces structured refinements to the plan — not free-form conversation. Agent updates the plan/validations based on feedback.

### Deploy Targets

Task includes an optional deploy target. UI provides a picker with these options:

| Target | Description | "Done" means |
|--------|-------------|-------------|
| **Hive Production** | Docker compose on Hive via GHCR + Watchtower | Container running new image, health check passes |
| **GitHub PR** | Deliverable is a merged PR | PR opened, CI green, merged to target branch |
| **Google Drive** | Deliverable is a file/folder uploaded to Drive | File uploaded to specified folder, shareable link generated |
| **None** | No deploy (docs, design, research, planning) | Task completed, no deploy step |

Deploy targets are discovered from the ops directory (`core-ops/targets/`). GitHub PR
is a built-in target type (repo + branch configurable per project).

The deploy target flows through to the deployer agent during execution and determines
what "deployment verification" means for the validator.

### Context Cascade

When an agent receives a task for planning or execution, it gets:

```
Project context (name, description, repo)
  → Epic context (name, description, scope)
    → Task: What + Why (human-authored)
      → Plan: How (agent-generated, human-approved)
        → Validations (approved criteria for success)
          → Deploy target (where it goes)
            → Attachments (screenshots, specs, files)
```

This is the "sufficient context" stack. Each layer enriches the next.

### Shared Upload Module

**Critical constraint**: attachments use the exact same `allow_upload` + `AttachmentStorage` pipeline as chat. No duplicate implementation. The bottom sheet form includes a `<.live_file_input>` wired to the same upload config, and `AttachmentStorage.persist_upload/1` handles storage.

## Consequences

- Task creation accessible on mobile and desktop
- Structured What/Why/How ensures agents get sufficient context
- Validation model gives humans control over success criteria
- Deploy target integration connects tasks to infrastructure
- Reusing chat's upload module keeps the codebase DRY
- Plan + validation approval creates a human-in-the-loop gate before execution
