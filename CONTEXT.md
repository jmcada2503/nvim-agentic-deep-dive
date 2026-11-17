# Deep Dive

A Neovim plugin that helps a developer understand how one feature works in a codebase (or several) by building a navigable, code-anchored graph of how the feature's data moves, so they can design a change or debug a problem without reading everything.

## Language

**Deep dive**:
One persisted investigation of one feature, owning one Flow graph and its history.
_Avoid_: Research session, analysis, scan

**Flow graph**:
The graph of Steps connected by Flow edges that explains how a feature's data moves. A Deep dive has one root Flow graph, and each Composite step holds a child Flow graph one level down. A Flow graph may span several repositories.
_Avoid_: Diagram, map, call graph

**Step**:
A node of the Flow graph. Either an action that does one thing to the data, or a Decision step. Explained in plain language. Is a Leaf step or a Composite step.
_Avoid_: Node, stage, function

**Leaf step**:
A Step with no child Flow graph, anchored to exactly one contiguous Anchor.
_Avoid_: Atomic step, simple node

**Composite step**:
A Step that owns a child Flow graph holding the details of one logical step, and optionally a single main Anchor. Zooming in opens the child graph.
_Avoid_: Group node, subgraph, container

**Decision step**:
A Step that chooses which Step follows, depending on the data or a condition. A loop is a Decision step with an edge back to an earlier Step.
_Avoid_: Branch node, conditional, loop node

**Group**:
A flat display label on a Step naming the repository or service it belongs to; it tells repos and services apart within one Flow graph.
_Avoid_: Namespace, module, layer

**Anchor**:
A file and line range a Step points at, resolved when the Flow graph is built and never at lookup time.
_Avoid_: Link, reference, pointer

**Call site**:
The Anchor in a Composite step's code where it invokes one of its child Steps. Optional; a child Step whose code sits inline in the parent has none.
_Avoid_: Caller, invocation, reference

**Data shape**:
A tracked structure (payload, record, struct) relevant to the feature; Flow edges carry it.
_Avoid_: Model, schema, DTO

**Flow edge**:
Data moving from one Step to the next, labelled with the Data shape it carries (and the condition, when leaving a Decision step).
_Avoid_: Link, connection, arrow

**Workspace**:
The set of repositories a Deep dive may span, and how they connect to each other.
_Avoid_: Project, monorepo

**Boundary**:
A Step whose far side lies outside the repository being read. Resolved when the Workspace already knows the other repository, or when the user grants access; otherwise unresolved.
_Avoid_: External call, integration point

**Revision**:
A recorded change to the Flow graph after its initial build, made because the graph was wrong or missing part of the flow. Revisions can be diffed. Only an accepted Pending revision becomes a Revision.
_Avoid_: Edit, version, update

**Revision proposal**:
A suggestion, raised by the agent while answering a question or by the user, that the Flow graph is wrong or incomplete at a given Step, with the reason. It changes nothing until the user accepts it, which starts a Fix run.
_Avoid_: Flag, issue, report

**Fix run**:
A scoped agent run, started from an accepted Revision proposal, that investigates the code and produces a Pending revision changing as little as possible.
_Avoid_: Re-dive, refresh, rebuild

**Validator**:
The deterministic check that a Flow graph is well-formed and that its Anchors and Data shape definitions point at real code. Judges existence and structure, never whether the flow is right.
_Avoid_: Linter, checker, verifier

**Critic**:
An adversarial agent, independent of the one building the graph, that reads the code and challenges whether the Flow graph describes the flow correctly and completely. The graph is only done when builder and Critic agree.
_Avoid_: Reviewer, judge, verifier agent

**Risk**:
One suspected error in the Flow graph raised by the Critic, with its justification and evidence Anchors. The builder must fix it or rebut it; unlike a Revision proposal, the user never sees or accepts it unless the loop gets stuck.
_Avoid_: Issue, finding, flag

**Repair round**:
One return to the builder carrying Validator errors and open Risks, answered by fixes or rebuttals.
_Avoid_: Retry, iteration

**Pending revision**:
The output of a Fix run, shown as a diff with its reasons, awaiting the user's accept or reject. Rejected ones leave no trace.
_Avoid_: Draft, candidate
