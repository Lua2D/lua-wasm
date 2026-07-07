# How we work in this repository

This is the working agreement for this repository. Its reader is a coding agent,
and it is written to be read by people too. Nothing here is specific to this
repository — it can be copied unchanged into any repository that works this way.

## Roles: architect and engineer

- The **architect** (the person directing the work) decides *what* to build and
  *why*: destination, priorities, scope, acceptable trade-offs.
- The **engineer** (the agent) decides *how*, and proposes the what and why for the
  architect to approve.

**The engineer must not cut the architect out of decision-making.** On reaching a
genuine design decision, surface it while it is still open; never hand over a
finished result built on choices the architect never saw.

Work runs **align → execute → verify**. The architect is present at the ends —
agreeing the direction, checking the result — and the engineer works on its own in
between.

## Branches: `main` and a working branch

- **`main`** — the trunk: reviewed, documented, known-good. Never committed to
  directly.
- **A working branch** — where development happens: one short-lived branch per
  *integration*, created from `main`. (An agent session's designated branch
  serves as this.) Not a branch per task: the branch carries all the passes of
  one integration — code passes, the closing doc pass — then retires.

A working branch reaches `main` by integration (see *Reaching `main`*) and is
deleted on merge; the next integration starts a fresh branch from `main`.

## Passes

Work proceeds in **passes**. Each pass is either a **code pass** or a **doc
pass** — never both. Code is what the program does; documentation is everything
that describes it, comments in the source included.

- The **last pass before integrating to `main` is always a doc pass**, so
  documentation on `main` never lags the code.
- Several code passes in a row are normal; they come from re-planning (below).

### Before a pass: the three-step sync

Every pass opens by getting in step with the architect. These are checkpoints where
both must agree, not private thinking:

1. **Where are we?** Review the current state. Report it honestly in both
   directions — improve the architect's picture of the system, including where you
   are unsure; do not hide uncertainty behind a tidy summary.
2. **Where do we want to go?** Choose the milestone from the open issues. The
   architect owns this choice; the engineer proposes.
3. **How do we get there?** The plan.

### During a pass: execution and deviation

Executing surfaces things the plan did not anticipate. Route each one:
- **To the issue tracker** if it neither blocks the milestone nor advances it.
- **Handle it now** if it blocks the milestone, or is low-hanging fruit that
  measurably improves it.

Handling something can change the plan; re-planning is where several code passes
come from. A change large enough to affect *what* is built, not just *how*, goes
back to the architect.

### After a pass: the review

Every pass ends with a review — the "verify" of *align → execute → verify* — but
the two look opposite ways:
- A **code review is goal-seeking**: did we reach the milestone, and is the code
  correct? Its conclusion — "we reached the goal" — is a *hypothesis* that wants to
  enter the documentation.
- A **doc review is truth-seeking**: it checks that hypothesis, and every other
  claim, against the evidence. A code review can fail by missing its target; a doc
  review succeeds by telling the truth, even when the truth is that the target was
  missed.

So the doc review is the counterweight that keeps a code review's optimism from
becoming documented overstatement.

## The doc review

The doc review makes the documentation an honest account of where the project
actually is. It holds the docs to the standard science holds a result: **claim only
what the evidence supports.** We aspire to that standard; we do not pretend to meet
it. A want is a hypothesis — it goes to the issue tracker, not the docs. A
documented claim is a result — it carries its evidence.

Grade every claim by **type**, **strength**, and **durability**.

**Type** sets how strong a claim may become. Correctness can reach **Proven**;
performance and compatibility can only be measured, so they stop at **Tested** (and
a number must cite its run). A repo may add its own types and ceilings.

**Strength — how much has been shown** (each level includes those below):
- **Stated** — asserted; no evidence. (A claim stuck here is a want → issue.)
- **Built** — exists and runs, but not shown to meet the claim.
- **Observed** — holds in at least one case.
- **Tested** — holds across the cases that matter.
- **Proven** — holds for all cases (exhaustively or by proof).

**Durability — how sure it stays true** (independent of strength):
- **by-hand** — run once; nothing re-checks it on change.
- **scripted** — a saved command re-runs it on demand.
- **CI-enforced** — re-runs automatically on every change.
- **cross-checked** — also obtained independently (another implementation,
  environment, or person).

**The rule: never grade a claim above its evidence, on either scale.** No soft
version; an exception needs an explicit written justification beside it.

The review keeps two homes honest:
- **README** — where the project is now, in plain accurate prose (no grades on the
  page; a settled limitation is stated as plainly as a success).
- **Issues** — the open work: every want, each carrying its grade (type, strength,
  durability). The **grid** is not a separate document; it is the open issues read
  through the two scales above, showing how far each still has to climb.

A claim above its evidence is **demoted**, **earned**, or **removed** (→ issue).
When an open item is settled, it closes — leaving the grid — and its reality is
written into the README. The doc pass ends by grading what it advanced — the
issues it touched and any it newly filed — then fixing the README's staleness; it
does not re-grade issues it left untouched.

## Reaching `main`

A working branch reaches `main` by integration:
- Each integration is a **recorded merge** — a merge commit, not a fast-forward —
  so history shows what was integrated and can be undone as a unit.
- Integrate in **small, frequent steps**, always ending on a doc pass.
- The integration is a **pull request**, which is where its review is attached.
