# Adversarial Critic with mandatory agreement validates every stage

A Flow graph's logic (do these Steps really call each other, is a Step missing, is a Boundary real) can't be checked cheaply without LSP or treesitter, which v1 doesn't use. So validation is split: a deterministic, text-only Validator checks structure and that Anchors exist and match, and an independent read-only Critic agent challenges the logic by raising Risks the builder must fix or rebut. A stage passes only when the Validator is clean and builder and Critic agree with no open Risks. We accept roughly double the token cost in exchange for correctness, which is the product's core promise.

## Considered Options

- Validator-only stage gate with repair-via-resume: cheap, but catches only existence and structure errors, not wrong flow.
- Validator exposed as an MCP tool the agent calls mid-run: needs per-CLI wiring and agents may skip calling it.
- Critic forked from the builder's session: inherits the builder's blind spots.
- Letting minor Risks stay open: leaves silent doubt in a graph users are meant to trust.

## Consequences

- The loop stops on repetition, not a round count: the same Validator error twice (detected by code) or the same Risk raised again after rebuttal (judged by the Critic) means stuck; a large per-stage token budget (default 10x the stage's first build turn) is the backstop. Stuck hands the decision to the user.
- A Risk against an already-accepted stage reopens it (and its expanded children) rather than becoming a post-dive Revision.
- Fix runs go through the same loop, with the Critic also enforcing minimal change.
