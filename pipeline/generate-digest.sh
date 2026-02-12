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

# Step 2: Build the prompt (use Python for safe template substitution)
log "Step 2: Building Claude prompt..."
PROMPT_FILE=$(mktemp /tmp/morning-digest-prompt-XXXXXX.md)
trap "rm -f '$PROMPT_FILE'" EXIT

python3 -c "
import json, sys
template = open('$SCRIPT_DIR/prompt-template.md').read()
feed_data = open('$FEED_FILE').read()
prompt = template.replace('{{FEED_DATA}}', feed_data)
with open('$PROMPT_FILE', 'w') as f:
    f.write(prompt)
"

# Step 3: Generate article with Claude
log "Step 3: Generating article with Claude..."
ARTICLE_FILE=$(mktemp /tmp/morning-digest-article-XXXXXX.md)
trap "rm -f '$PROMPT_FILE' '$ARTICLE_FILE'" EXIT

claude -p --model sonnet < "$PROMPT_FILE" > "$ARTICLE_FILE" 2>>"$LOGFILE"

if [ ! -s "$ARTICLE_FILE" ]; then
  log "ERROR: Claude returned empty response"
  exit 1
fi

log "Article generated ($(wc -w < "$ARTICLE_FILE") words)"

# Step 4: Assemble Hugo post with frontmatter
log "Step 4: Writing Hugo post..."
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
summary: "Daily briefing from independent media, Bitcoin, and macro finance."
showToc: true
---

FRONTMATTER
  cat "$ARTICLE_FILE"
} > "$POST_FILE"

log "Post written: $POST_FILE"

# Step 5: Build Hugo site
log "Step 5: Building Hugo site..."
cd "$SITE_DIR"
~/.local/bin/hugo --minify 2>>"$LOGFILE"

log "Site built successfully."
log "=== Pipeline complete ==="
