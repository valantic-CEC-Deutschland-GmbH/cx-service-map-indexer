# Changelog

## [1.0.0] - 2026-04-22

### Added
- Initial release
- Fetch all services and case studies from CX Service Map Strapi API (paginated)
- Claude CLI-based analysis with structured `prompt.md` system prompt
- RAG-optimized markdown output with heading-based chunk context
- Change detection between runs (SHA-256 hash comparison, skip if unchanged)
- Optional upload to Workoflow knowledge base via KB upload API
- CLI flags: `--force`, `--upload`, `--dry-run`, `--model`, `--effort`
- Data slimming: strips duplicated nested objects, binary asset metadata, and localizations to reduce raw data from ~6MB to ~1.4MB
- Cross-reference sections: services by service line, case studies by industry, technology directory
- Search keywords section for maximum RAG recall
