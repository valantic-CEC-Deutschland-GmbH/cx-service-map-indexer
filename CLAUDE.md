# CX Service Map Indexer

Fetches services and case studies from the valantic CX Service Map (Strapi CMS), uses Claude CLI to produce a RAG-optimized markdown knowledge base, and optionally uploads it to the Workoflow knowledge base.

## Usage

```bash
cp .env.example .env   # fill in tokens
./index.sh             # fetch + analyze
./index.sh --upload    # fetch + analyze + upload to KB
./index.sh --dry-run   # fetch only, no Claude analysis
./index.sh --force     # re-analyze even if data unchanged
```

## Architecture

- `index.sh` — Shell orchestrator (fetch API data, invoke Claude, upload)
- `prompt.md` — System prompt defining Claude's analysis and output structure
- `tmp/` — Raw API data (cached between runs for change detection)
- `output/` — Generated markdown files

## Pattern

Follows the same pattern as `gitlab-indexer/`: shell fetches raw data → Claude CLI analyzes with structured prompt → markdown output for RAG indexing.
