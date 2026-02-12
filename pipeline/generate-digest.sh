#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SITE_DIR="$PROJECT_DIR/site"
LOG_DIR="$PROJECT_DIR/logs"
TODAY=$(date +%Y-%m-%d)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/$TODAY.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

log "=== Morning Digest Pipeline - $TODAY ==="

# Step 1: Fetch feeds
log "Step 1: Fetching RSS feeds..."
cd "$PROJECT_DIR"
node pipeline/fetch-feeds.js 2>>"$LOGFILE"

FEED_FILE="$PROJECT_DIR/raw/$TODAY.json"
if [ ! -f "$FEED_FILE" ]; then
  log "ERROR: Feed file not created: $FEED_FILE"
  exit 1
fi

ITEM_COUNT=$(python3 -c "import json; print(json.load(open('$FEED_FILE'))['totalItems'])")
log "Fetched $ITEM_COUNT items"

if [ "$ITEM_COUNT" -eq 0 ]; then
  log "WARNING: No items fetched. Skipping article generation."
  exit 0
fi

# Step 2: Research topics via web search
log "Step 2: Researching topics..."
RESEARCH_FILE="$PROJECT_DIR/raw/$TODAY-research.md"
bash "$SCRIPT_DIR/research-topics.sh" 2>>"$LOGFILE" || {
  log "WARNING: Research step failed. Continuing without research."
  echo "No research data available." > "$RESEARCH_FILE"
}
log "Research complete ($(wc -w < "$RESEARCH_FILE") words)"

# Step 3: Build the prompt (use Python for safe template substitution)
log "Step 3: Building Claude prompt..."
PROMPT_FILE=$(mktemp /tmp/morning-digest-prompt-XXXXXX.md)
trap "rm -f '$PROMPT_FILE'" EXIT

python3 -c "
import json, sys
template = open('$SCRIPT_DIR/prompt-template.md').read()
feed_data = open('$FEED_FILE').read()
research = open('$RESEARCH_FILE').read()
prompt = template.replace('{{FEED_DATA}}', feed_data).replace('{{RESEARCH}}', research)
with open('$PROMPT_FILE', 'w') as f:
    f.write(prompt)
"

# Step 4: Generate article with Claude
log "Step 4: Generating article with Claude..."
ARTICLE_FILE=$(mktemp /tmp/morning-digest-article-XXXXXX.md)
trap "rm -f '$PROMPT_FILE' '$ARTICLE_FILE'" EXIT

claude -p --model sonnet < "$PROMPT_FILE" > "$ARTICLE_FILE" 2>>"$LOGFILE"

if [ ! -s "$ARTICLE_FILE" ]; then
  log "ERROR: Claude returned empty response"
  exit 1
fi

log "Article generated ($(wc -w < "$ARTICLE_FILE") words)"

# Step 5: Extract summary from first paragraph
SUMMARY=$(python3 -c "
import sys
content = open('$ARTICLE_FILE').read().strip()
# Find first non-empty paragraph (skip any accidental blank lines)
paragraphs = [p.strip() for p in content.split('\n\n') if p.strip() and not p.strip().startswith('#')]
if paragraphs:
    first = paragraphs[0].replace('\"', '\\\\\"')
    # Truncate to ~200 chars at word boundary
    if len(first) > 200:
        first = first[:200].rsplit(' ', 1)[0] + '...'
    print(first)
else:
    print('Daily briefing from independent media, Bitcoin, and macro finance.')
")

# Step 6: Assemble Hugo post with frontmatter
log "Step 6: Writing Hugo post..."
POST_DIR="$SITE_DIR/content/posts"
mkdir -p "$POST_DIR"
POST_FILE="$POST_DIR/$TODAY.md"

TAGS=$(python3 -c "
import json
d = json.load(open('$FEED_FILE'))
cats = sorted(set(item['category'] for item in d['items'] if item.get('category')))
print(', '.join(f'\"{c}\"' for c in cats))
")

{
  cat <<FRONTMATTER
---
title: "Morning Digest — $(date '+%B %d, %Y')"
date: $TIMESTAMP
draft: false
tags: [$TAGS]
summary: "$SUMMARY"
description: "Morning Digest for $(date '+%B %d, %Y') — daily briefing from independent media, Bitcoin, and macro finance."
showToc: true
---

FRONTMATTER
  cat "$ARTICLE_FILE"
} > "$POST_FILE"

log "Post written: $POST_FILE"

# Step 7: Build Hugo site
log "Step 7: Building Hugo site..."
cd "$SITE_DIR"
~/.local/bin/hugo --minify 2>>"$LOGFILE"

log "Site built successfully."
log "=== Pipeline complete ==="
