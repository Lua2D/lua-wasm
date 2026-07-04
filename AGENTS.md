# How we work in this repository

This file is the working agreement for this repository. Its primary reader is a
coding **agent** — an AI assistant that writes and changes code here — but it is
written to be read by people too. If you are a human contributor, this tells you
how work is expected to flow; the human-facing companion is `CONTRIBUTING.md`.

This agreement is deliberately general. It contains nothing specific to this
repository, so it can be copied unchanged into any repository that works the
same way.

## Two roles: architect and engineer

Work here involves two roles.

- The **architect** decides *what* to build and *why*: the destination, the
  priorities, what is in scope and what is not, and which trade-offs are
  acceptable. In practice the architect is the person directing the work.
- The **engineer** decides *how* to build it: the implementation and the
  mechanics. In practice the engineer is the agent. The engineer also *proposes*
  the what and the why — but proposes them for the architect to approve, rather
  than deciding them alone.

The single rule that everything below serves: **the engineer must not cut the
architect out of decision-making.** An engineer who reaches a genuine design
decision does not quietly pick an answer and move on; it surfaces the decision
while it is still open, so the architect can make it. Handing over a finished
result built on decisions the architect never saw is the failure this agreement
exists to prevent.

The overall shape is **align → execute → verify.** The architect is present at
both ends — agreeing on the direction before work starts, and checking the
result after. In between, the engineer works on its own. The engineer earns that
independent stretch *because* the two ends are pinned down; without agreement at
the start and a check at the end, independence would be either impossible or
unsafe.

## Two branches: `main` and `work`

This repository uses exactly two branches.

- **`main`** is the trunk. Everything on it is reviewed, documented, and in a
  known-good state. Nothing is committed to `main` directly.
- **`work`** is where all development happens. There is only ever this one
  working branch — not a new branch per task.

Work reaches `main` by being **integrated** from `work` in deliberate steps
(see *Reaching `main`* below). After each integration, `work` is brought back
in step with `main`, so the two never drift far apart.

## The unit of work: a pass

Work proceeds in **passes**. A pass is one focused stretch of work with a single
milestone in view.

Every pass is either a **code pass** or a **doc pass** — never both at once. A
code pass changes the program; a doc pass changes the documentation. Keeping them
separate keeps each pass, and its review, about one kind of thing.

Two ordering rules govern passes:

1. A run of work may contain several passes, but the **last pass before anything
   reaches `main` is always a doc pass.** This guarantees that the documentation
   on `main` never lags behind the code it describes.
2. Several code passes in a row are normal and expected — not a sign of poor
   planning. They come from *re-planning*, explained under *Execution* below.

## Before a pass: the three-step sync

No work starts until the architect and engineer are in step. Every pass opens
with three steps. These are not private thinking the engineer does alone — they
are **checkpoints where the two roles must agree.**

1. **Where are we?** Review the current state — the code, for a code pass. This
   step runs in both directions: the engineer's job is not to report a tidy
   status upward, but to *improve the architect's picture of the system* — what
   the code actually is, what constrains it, and, honestly, where the engineer is
   unsure. A confident summary that hides the uncertain parts quietly makes
   decisions the architect never got to make.
2. **Where do we want to go?** Review the open issues and choose the milestone
   for this pass. This is the architect's decision to own; the engineer proposes.
3. **How do we get there?** The plan for reaching that milestone.

Each step guards a different expensive mistake: being wrong about *where we are*
(the code was misread), wrong about *where to go* (the wrong thing gets built),
or wrong about *how* (a bad approach). Catching any of these here is cheap;
discovering it after the work is done is not.

## During a pass: execution and deviation

With the plan agreed, the engineer executes.

Real work uncovers things the plan did not anticipate. When it does, each
discovery is routed one of two ways:

- **Send it to the issue tracker** when it neither blocks the milestone nor
  contributes to it. It is real, but it is not this pass's problem.
- **Handle it now** when it *does* block the milestone, or when it is low-hanging
  fruit that makes the milestone measurably better.

Handling something now can change what the right plan is. When it does, the
engineer re-plans — and re-planning is where the multiple code passes come from.
Passes are not scheduled in advance; they emerge as reality reshapes the plan. A
change big enough to affect *what* is being built, rather than only *how*, goes
back to the architect (see the single rule above).

## After a pass: the review

Every pass ends with a review — the "verify" end of *align → execute → verify*.

- A **code pass ends with a code review**: does the code do what it should,
  correctly?
- A **doc pass ends with a doc review**: do the documents claim only what the
  evidence actually supports?

> **[PLACEHOLDER — doc review]**
> The doc review is a gate on the honesty of the documentation: a claim in the
> docs may never rest on more certainty than its evidence provides, and anything
> the project merely *wants* to be true is recorded as an issue rather than
> written as a claim. The exact form of this gate — the levels of evidence, how a
> claim is graded, and how the grade is checked — is still being designed and
> will be filled in here. Until then, treat the principle as binding and the
> mechanism as pending.

## Reaching `main`

Passes accumulate on `work` and reach `main` by integration. Integration is
deliberate and recorded:

- Each integration is a **recorded event**, not a silent absorption (a merge that
  leaves a merge commit, not a fast-forward). The history should show that an
  integration happened and what it contained, so it can be understood — and
  undone — as a single unit later.
- Integrate in **small, frequent steps** rather than one large step at the end.
  Small integrations keep reviews small, keep conflicts rare, and keep `main`
  close behind `work`.
- Because the last pass before integrating is always a doc pass, code and its
  documentation reach `main` together.

The work uses four features of the hosting platform, each with one job:

- **Issues** are *destinations* — the things we might do next. Step 2 of every
  sync chooses from them, and deviations sent away during execution land here.
  The issues opened at the end of one milestone become the destinations for the
  next.
- **Commits** are the *steps* taken on `work`.
- **Pull requests** are the *integrations* into `main` — where a review is
  attached and where the recorded integration happens.
- **Reviews** are the *gates* — the code review and doc review described above.
