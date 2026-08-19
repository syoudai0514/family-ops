# Architecture Decision Records

Lightweight ADRs for decisions made during implementation that aren't
themselves part of the vendored v6 design package (`docs/design/v6/`, which
remains normative and is never edited by an ADR). An ADR here records a
decision this repository's implementation committed to, and why.

## Index

- [0001](0001-v6-baseline-commitment.md) — Commit to the v6 design package as
  the sole normative source; no v7

## Format

Each ADR is a short Markdown file: title, status, context, decision,
consequences. Number sequentially (`0001-`, `0002-`, ...). Superseding an
earlier decision adds a new ADR and marks the old one's status
`Superseded by NNNN`, rather than editing history away.
