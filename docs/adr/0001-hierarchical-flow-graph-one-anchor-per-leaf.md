# Hierarchical Flow graph, one Anchor per Leaf step

A Step whose code is not contiguous could have carried several Anchors (one primary, the rest supporting). Instead a Leaf step has exactly one contiguous Anchor, and a logical step spanning scattered code becomes a Composite step whose child Flow graph holds the pieces, each a Leaf step. This gives developers zoom levels (overview first, details on demand), lets the validator enforce "one Leaf, one contiguous range", and removes primary/supporting Anchor logic. Repositories are not a hierarchy level: one Flow graph spans repos and tells them apart with a Group label. Loops are not special: a loop is a Decision step with an edge back to an earlier Step.

Consequence: every level is generated up front at dive time (zooming must never trigger research), so the dive pipeline expands Composite steps in resumable stages.
