# Contributing to openshift-twonode-guide

Thank you for your interest in contributing. This repository is a technical reference for Two-Node OpenShift deployments. Contributions are welcome in any of the following areas:

- **Demo validation** — run an existing stub demo against a real cluster and update the README with results
- **New demos** — add a new edge workload scenario
- **Deployment records** — document a new environment or cluster version
- **Bug fixes** — correct commands, update version references, fix broken links
- **Architecture Decision Records** — propose a new ADR for a significant technical choice

---

## Getting Started

### 1. Fork and clone

```bash
git clone https://github.com/YOUR_USERNAME/openshift-twonode-guide
cd openshift-twonode-guide
```

### 2. Set up the documentation locally

```bash
pip install -r requirements-docs.txt
mkdocs serve
# Opens a live-reloading preview at http://localhost:8000
```

### 3. Make your changes, verify locally, then open a PR

```bash
mkdocs build --strict   # fails on broken links or malformed Markdown
```

---

## How to Add a New Demo

1. Create a directory under `docs/demos/` following the existing naming pattern:
   ```
   docs/demos/06-my-scenario/
   └── README.md
   ```

2. Use this structure in `README.md`:
   ```
   # Demo N: <Title> — <One-line Objective>

   **Objective**: ...

   ## Prerequisites
   ## Steps
   ## Validation
   ## Expected Output
   ## Troubleshooting
   ```

3. Add the demo to the `nav` section of `mkdocs.yml`:
   ```yaml
   - 06 My Scenario: demos/06-my-scenario/README.md
   ```

4. Update the status table in `docs/demos/index.md`.

5. Open a GitHub issue referencing the demo number (or close an existing one if this validates a stub).

---

## How to Write an Architecture Decision Record (ADR)

ADRs live in `docs/adrs/`. Copy the format from an existing ADR:

```
# ADR-NNN: <Decision Title>

## Status
Accepted | Superseded by ADR-XXX

## Context
<Why is this decision needed?>

## Decision
<What was decided?>

## Consequences
<What are the trade-offs?>
```

Number sequentially. Add the new ADR to the `nav` in `mkdocs.yml`.

---

## How to Add a Deployment Record

1. Create `docs/deployments/YYYY-MM-DD-<environment>.md`.
2. Cover: prerequisites, ordered steps, issues encountered, validation output, rollback procedure.
3. Add an entry to the table in `docs/deployments/index.md`.
4. Update `docs/changelog.md` with a brief entry.

---

## Commit Message Style

Use conventional commits:

```
feat: add demo 06 — edge ML model serving
fix: correct fence_redfish --systems-uri flag in demo 01
docs: add deployment record for AWS bare metal 2026-07
chore: bump mkdocs-material to 9.6
```

---

## Reporting Issues

Use [GitHub Issues](https://github.com/tosin2013/openshift-twonode-guide/issues). Tag the issue with the relevant label:

| Label | Use for |
|---|---|
| `demo-validation` | Running a stub demo and documenting results |
| `bug` | Incorrect commands or broken instructions |
| `enhancement` | New demos, guides, or features |
| `documentation` | Typos, clarifications, structural improvements |
