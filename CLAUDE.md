# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**assay** is a parallel proof and annotation language for Gleam that uses graded modal type theory to verify properties the type system can't reach: effects, resource linearity, data privacy, and capability permissions.

Annotations live in `.assay` sidecar files alongside Gleam source. The syntax is algebra-parametric — the same shape works for sets (effects), naturals (usage/linearity), and lattices (privacy/capabilities). The primary consumer is LLM agents, not humans.

## Current State

The project is in the research and planning phase. There is no code, build system, or tests yet. See RESEARCH.md for the eight research areas and their suggested investigation order:

1. Prior art survey — know what exists before building
2. Gleam AST and tooling — can we parse Gleam? (gates everything else)
3. Effect system design — first checker target, most immediate value
4. Annotation language design — informed by AST and effect research
5. Core formalism — minimal graded modal type theory for the checker
6. Linearity and resource tracking
7. Privacy and capability lattices
8. LLM integration and agent workflow

## Theoretical Foundations

The theory is based on graded modal type theory as developed in Granule (Orchard et al., ICFP 2019) and the coeffect literature (Petricek et al.). Key concepts:

- **Grading algebras** (semirings, lattices) parameterize the checker — effects use sets, linearity uses natural numbers, privacy uses lattices
- **Bidirectional type checking** is the core algorithm pattern from Granule
- The checker verifies that Gleam implementations are consistent with `.assay` annotations

## Key Design Decisions

- **Sidecar specs, not language extensions.** Gleam code stays clean; annotations are separate.
- **Agents first.** Annotations are designed to be machine-written and machine-read.
- **Incremental adoption.** Only annotated modules are checked; the rest is ignored.
- **Sound foundations.** Building engineering on proven type theory, not inventing new formalism.
- **Implementation language is TBD.** Tradeoffs between Gleam (ecosystem), Rust (performance), and Haskell (type theory tooling) are unresolved.
