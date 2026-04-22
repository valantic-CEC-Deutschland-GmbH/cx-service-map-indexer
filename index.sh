#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$SCRIPT_DIR/tmp"
OUTPUT_DIR="$SCRIPT_DIR/output"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
ENV_FILE="$SCRIPT_DIR/.env"

# Defaults
FORCE=false
UPLOAD=false
DRY_RUN=false
MODEL="sonnet"
EFFORT="medium"
PAGE_SIZE=100

# --- Argument parsing ---

usage() {
    echo "Usage: $0 [--force] [--upload] [--dry-run] [--model MODEL] [--effort LEVEL]"
    echo ""
    echo "  --force            Re-analyze even if data unchanged"
    echo "  --upload           Upload generated markdown to knowledge base"
    echo "  --dry-run          Fetch data only, skip Claude analysis and upload"
    echo "  --model MODEL      Claude model (default: sonnet)"
    echo "  --effort LEVEL     Claude effort level (default: medium)"
    echo ""
    echo "Examples:"
    echo "  $0                          Fetch + analyze"
    echo "  $0 --upload                 Fetch + analyze + upload to KB"
    echo "  $0 --dry-run                Fetch data only"
    echo "  $0 --force --upload         Force re-analyze + upload"
    echo ""
    echo "Configuration: copy .env.example to .env and set your credentials."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --upload)
            UPLOAD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --effort)
            EFFORT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# --- Prerequisites ---

check_prerequisites() {
    local missing=()
    for cmd in claude curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required commands: ${missing[*]}"
        exit 1
    fi
}

# --- Load .env ---

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and set your credentials."
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    if [[ -z "${CX_API_BASE_URL:-}" ]]; then
        echo "ERROR: CX_API_BASE_URL not set in .env"
        exit 1
    fi
    if [[ -z "${CX_API_BEARER_TOKEN:-}" ]]; then
        echo "ERROR: CX_API_BEARER_TOKEN not set in .env"
        exit 1
    fi
}

# --- Strapi API helpers ---

strapi_get() {
    local endpoint="$1"
    curl -s --location --globoff \
        --header "Authorization: Bearer $CX_API_BEARER_TOKEN" \
        "${CX_API_BASE_URL}${endpoint}"
}

# Fetch all pages from a paginated Strapi endpoint
strapi_get_all() {
    local endpoint="$1"
    local page=1
    local tmp_file="$TMP_DIR/_pages.jsonl"
    : > "$tmp_file"

    while true; do
        local separator="?"
        [[ "$endpoint" == *"?"* ]] && separator="&"

        local response
        response=$(strapi_get "${endpoint}${separator}pagination[page]=${page}&pagination[pageSize]=${PAGE_SIZE}")

        local page_data
        page_data=$(echo "$response" | jq -c '.data[]' 2>/dev/null)
        local count
        count=$(echo "$response" | jq '.data | length // 0')

        if [[ "$count" -eq 0 ]]; then
            break
        fi

        echo "$page_data" >> "$tmp_file"

        local page_count
        page_count=$(echo "$response" | jq '.meta.pagination.pageCount // 1')
        local items_so_far
        items_so_far=$(wc -l < "$tmp_file")

        printf "\r  ... page %d/%s — %d items so far" "$page" "$page_count" "$items_so_far" >&2

        if [[ "$page" -ge "$page_count" ]]; then
            break
        fi
        page=$((page + 1))
    done

    printf "\n" >&2
    jq -s '.' "$tmp_file"
    rm -f "$tmp_file"
}

# --- Fetch all data ---

fetch_data() {
    echo "Fetching services..."
    local services
    services=$(strapi_get_all "/api/services?populate=*")
    local services_count
    services_count=$(echo "$services" | jq 'length')
    echo "  Total services: $services_count"

    echo "Fetching case studies..."
    local case_studies
    case_studies=$(strapi_get_all "/api/case-studies?populate=*")
    local case_studies_count
    case_studies_count=$(echo "$case_studies" | jq 'length')
    echo "  Total case studies: $case_studies_count"

    # Save intermediate files
    echo "$services" > "$TMP_DIR/_services.json"
    echo "$case_studies" > "$TMP_DIR/_case_studies.json"

    # Build raw_data.json with metadata using file-based input (data too large for args)
    local fetch_timestamp
    fetch_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Slim down services: strip binary asset metadata, localizations, and nested case study objects
    # (full case study data is already in the case_studies array — keep only title refs)
    jq '[.[] | del(.attributes.image, .attributes.files, .attributes.localizations, .attributes.service_provider) | .attributes.case_studies.data = [.attributes.case_studies.data[]? | {id: .id, attributes: {title: .attributes.title, slug: .attributes.slug}}]]' \
        "$TMP_DIR/_services.json" > "$TMP_DIR/_services_slim.json"
    mv "$TMP_DIR/_services_slim.json" "$TMP_DIR/_services.json"

    # Slim down case studies: replace full nested service objects with name-only refs
    # (full service data is already in the services array — no need to duplicate)
    # Also strip binary asset metadata
    jq '[.[] | .attributes.services.data = [.attributes.services.data[]? | {id: .id, attributes: {name: .attributes.name, slug: .attributes.slug}}] | del(.attributes.customer_image, .attributes.challenge_image, .attributes.files, .attributes.localizations)]' \
        "$TMP_DIR/_case_studies.json" > "$TMP_DIR/_case_studies_slim.json"

    jq -n \
        --arg ts "$fetch_timestamp" \
        --arg source_url "${KB_SOURCE_URL:-}" \
        --argjson sc "$services_count" \
        --argjson csc "$case_studies_count" \
        --slurpfile services "$TMP_DIR/_services.json" \
        --slurpfile case_studies "$TMP_DIR/_case_studies_slim.json" \
        '{
            metadata: {
                fetched_at: $ts,
                source: "CX Service Map (Strapi CMS)",
                source_url: $source_url,
                services_count: $sc,
                case_studies_count: $csc
            },
            services: $services[0],
            case_studies: $case_studies[0]
        }' > "$TMP_DIR/raw_data_new.json"

    rm -f "$TMP_DIR/_services.json" "$TMP_DIR/_case_studies.json" "$TMP_DIR/_case_studies_slim.json"

    echo "  Saved to tmp/raw_data_new.json ($services_count services, $case_studies_count case studies)"
}

# --- Detect changes ---

detect_changes() {
    if [[ ! -f "$TMP_DIR/raw_data.json" ]]; then
        echo "  First run — no previous data to compare."
        mv "$TMP_DIR/raw_data_new.json" "$TMP_DIR/raw_data.json"
        return 0
    fi

    # Compare data content (ignoring metadata.fetched_at timestamp)
    local old_hash new_hash
    old_hash=$(jq -S '{services: .services, case_studies: .case_studies}' "$TMP_DIR/raw_data.json" | sha256sum | cut -d' ' -f1)
    new_hash=$(jq -S '{services: .services, case_studies: .case_studies}' "$TMP_DIR/raw_data_new.json" | sha256sum | cut -d' ' -f1)

    if [[ "$old_hash" == "$new_hash" ]]; then
        echo "  No changes detected since last run."
        rm "$TMP_DIR/raw_data_new.json"
        if [[ "$FORCE" == "true" ]]; then
            echo "  --force specified, continuing anyway."
            return 0
        else
            echo "  Use --force to re-analyze. Exiting."
            return 1
        fi
    fi

    # Show what changed
    local old_services new_services old_cases new_cases
    old_services=$(jq '.services | length' "$TMP_DIR/raw_data.json")
    new_services=$(jq '.services | length' "$TMP_DIR/raw_data_new.json")
    old_cases=$(jq '.case_studies | length' "$TMP_DIR/raw_data.json")
    new_cases=$(jq '.case_studies | length' "$TMP_DIR/raw_data_new.json")

    echo "  Changes detected!"
    echo "    Services: $old_services → $new_services"
    echo "    Case Studies: $old_cases → $new_cases"

    mv "$TMP_DIR/raw_data_new.json" "$TMP_DIR/raw_data.json"
    return 0
}

# --- Claude analysis ---

analyze_with_claude() {
    local output_file="$OUTPUT_DIR/cx_service_map_knowledge_base.md"

    echo "  Running Claude analysis (model: $MODEL, effort: $EFFORT)..."

    local claude_output
    local exit_code=0

    claude_output=$(cd "$TMP_DIR" && claude -p \
        --model "$MODEL" \
        --effort "$EFFORT" \
        --no-session-persistence \
        --dangerously-skip-permissions \
        --tools "Read,Glob,Grep" \
        --system-prompt "$(cat "$PROMPT_FILE")" \
        "Analyze the CX Service Map data. Start by reading raw_data.json for the complete dataset of services and case studies. Output the full markdown document as your response — do not write any files." \
        < /dev/null) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "  FAILED: Claude exited with code $exit_code"
        echo "$claude_output" | head -10 | sed 's/^/    /'
        return 1
    fi

    # Strip any preamble before the first markdown heading
    claude_output=$(echo "$claude_output" | sed -n '/^# /,$p')

    if [[ -z "$claude_output" ]]; then
        echo "  FAILED: No markdown heading in Claude output"
        return 1
    fi

    mkdir -p "$OUTPUT_DIR"
    echo "$claude_output" > "$output_file"

    local line_count word_count
    line_count=$(wc -l < "$output_file")
    word_count=$(wc -w < "$output_file")
    echo "  DONE → $output_file ($line_count lines, $word_count words)"
}

# --- Upload to knowledge base ---

upload_to_kb() {
    local output_file="$OUTPUT_DIR/cx_service_map_knowledge_base.md"

    if [[ ! -f "$output_file" ]]; then
        echo "  ERROR: Output file not found: $output_file"
        return 1
    fi

    echo "  Uploading to knowledge base..."

    local response
    local http_code
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "X-Prompt-Token: $KB_PROMPT_TOKEN" \
        -F "file=@$output_file" \
        -F "document_type=${KB_DOCUMENT_TYPE:-general}" \
        -F "source_url=${KB_SOURCE_URL}" \
        "$KB_UPLOAD_URL")

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        202)
            echo "  Upload accepted (202). Document ID: $(echo "$body" | jq -r '.id // "unknown"')"
            ;;
        409)
            echo "  Document unchanged (409 — duplicate content hash). No re-upload needed."
            ;;
        *)
            echo "  Upload failed (HTTP $http_code):"
            echo "$body" | jq '.' 2>/dev/null || echo "$body"
            return 1
            ;;
    esac
}

# --- Main ---

main() {
    echo "========================================="
    echo "  CX Service Map Indexer"
    echo "========================================="
    echo ""

    check_prerequisites
    load_env

    mkdir -p "$TMP_DIR"
    mkdir -p "$OUTPUT_DIR"

    echo "API: $CX_API_BASE_URL"
    echo "Model: $MODEL | Effort: $EFFORT"
    echo "Force: $FORCE | Upload: $UPLOAD | Dry-run: $DRY_RUN"
    echo ""

    # Phase 1: Fetch data
    echo "--- Phase 1: Fetching data ---"
    fetch_data

    # Phase 2: Detect changes
    echo ""
    echo "--- Phase 2: Change detection ---"
    if ! detect_changes; then
        exit 0
    fi

    # Phase 3: Claude analysis
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "--- Dry run — skipping analysis and upload ---"
        echo "Data saved to: $TMP_DIR/raw_data.json"
        exit 0
    fi

    echo ""
    echo "--- Phase 3: Claude analysis ---"
    if ! analyze_with_claude; then
        echo "Analysis failed."
        exit 1
    fi

    # Phase 4: Upload
    if [[ "$UPLOAD" == "true" ]]; then
        echo ""
        echo "--- Phase 4: Upload to knowledge base ---"
        upload_to_kb
    fi

    echo ""
    echo "========================================="
    echo "  Done!"
    echo "========================================="
    echo "  Output: $OUTPUT_DIR/cx_service_map_knowledge_base.md"
    if [[ "$UPLOAD" == "true" ]]; then
        echo "  Uploaded: Yes"
    else
        echo "  Uploaded: No (use --upload to upload)"
    fi
    echo "========================================="
}

main
