# CX Service Map Indexer

Fetches all services and case studies from the valantic CX Service Map (Strapi CMS), uses Claude CLI to produce a RAG-optimized markdown knowledge base, and optionally uploads it to the Workoflow knowledge base for AI-powered search and retrieval.

## How it works

```
Strapi API (services + case studies)
    ↓ fetch (paginated, all pages)
raw_data.json (1.4 MB, deduplicated)
    ↓ Claude CLI analysis
cx_service_map_knowledge_base.md (structured markdown)
    ↓ upload (optional)
Workoflow Knowledge Base (RAG indexing)
```

1. **Fetch**: Shell script fetches all 130+ services and 112+ case studies from the Strapi API, handling pagination automatically
2. **Analyze**: Claude CLI reads the raw JSON and produces intelligent, cross-referenced markdown — not a dumb template, but context-aware prose optimized for RAG chunking (512-token heading-based splits)
3. **Upload**: Optionally uploads the generated markdown to the Workoflow knowledge base via the KB upload API

## Prerequisites

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command)
- `curl`, `jq`
- API credentials (see Configuration)

## Configuration

```bash
cp .env.example .env
# Edit .env with your credentials
```

| Variable | Description |
|----------|-------------|
| `CX_API_BASE_URL` | Strapi CMS base URL |
| `CX_API_BEARER_TOKEN` | Strapi API bearer token |
| `KB_UPLOAD_URL` | Workoflow KB upload endpoint |
| `KB_PROMPT_TOKEN` | Workoflow prompt token (from /profile/) |
| `KB_SOURCE_URL` | Source URL for document attribution |
| `KB_DOCUMENT_TYPE` | Document type (`general` or `project_knowledge`) |

## Usage

```bash
# Fetch data + analyze with Claude
./index.sh

# Fetch + analyze + upload to knowledge base
./index.sh --upload

# Fetch data only (no Claude analysis)
./index.sh --dry-run

# Force re-analysis even if data hasn't changed
./index.sh --force

# Use a different model or effort level
./index.sh --model opus --effort high
```

### CLI Options

| Flag | Default | Description |
|------|---------|-------------|
| `--force` | `false` | Re-analyze even if no data changes detected |
| `--upload` | `false` | Upload generated markdown to Workoflow KB |
| `--dry-run` | `false` | Fetch data only, skip analysis and upload |
| `--model MODEL` | `sonnet` | Claude model to use |
| `--effort LEVEL` | `medium` | Claude effort level |

## Re-runs & Incremental Updates

The indexer is designed to run multiple times:

- Raw API data is cached in `tmp/raw_data.json`
- On re-run, fetched data is compared with the cache (SHA-256 hash of data content, ignoring timestamps)
- If no changes detected → exits early (use `--force` to override)
- If changes detected → shows diff summary (e.g., "Services: 130 → 132") and re-analyzes
- The KB upload API deduplicates by content hash — uploading identical content returns 409

## Output

- `tmp/raw_data.json` — Raw API data (cached for change detection)
- `output/cx_service_map_knowledge_base.md` — Generated knowledge base markdown

## Architecture

Follows the same pattern as [gitlab-indexer](https://github.com/valantic-CEC-Deutschland-GmbH/gitlab-indexer):

- `index.sh` — Shell orchestrator (fetch → analyze → upload)
- `prompt.md` — System prompt defining Claude's analysis rules and output structure
- `.env` — Configuration (gitignored)

The prompt instructs Claude to:
- Cross-reference services with their case studies (bidirectional)
- Group services by service line and case studies by industry
- Flag incomplete services (placeholder descriptions)
- Include "CX Service Map" in every heading for RAG chunk context
- Generate a comprehensive search keywords section for maximum recall
