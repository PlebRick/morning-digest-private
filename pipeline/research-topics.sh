#!/usr/bin/env bash
set -euo pipefail

# Extracts headlines from the daily feed JSON and runs a web search
# research step via Claude, outputting structured research notes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TODAY=$(date +%Y-%m-%d)
FEED_FILE="$PROJECT_DIR/raw/$TODAY.json"
RESEARCH_FILE="$PROJECT_DIR/raw/$TODAY-research.md"

if [ ! -f "$FEED_FILE" ]; then
  echo "ERROR: Feed file not found: $FEED_FILE" >&2
  exit 1
fi

# Extract headlines from feed JSON
HEADLINES=$(python3 -c "
import json, sys
data = json.load(open('$FEED_FILE'))
for item in data['items']:
    title = item.get('title', '').strip()
    source = item.get('source', '').strip()
    if title:
        print(f'- [{source}] {title}')
")

if [ -z "$HEADLINES" ]; then
  echo "WARNING: No headlines extracted. Skipping research." >&2
  echo "No research data available." > "$RESEARCH_FILE"
  exit 0
fi

# Build research prompt
RESEARCH_PROMPT=$(cat <<'PROMPT_END'
You are a news researcher preparing background material for a journalist writing a daily digest article.

Below is a list of headlines from today's RSS feeds. For each major topic or story cluster, use web search to find:
- Key facts, data points, and context
- Notable quotes from officials or experts
- Relevant numbers (prices, statistics, vote counts, etc.)
- Source URLs for verification

## Instructions
- Group related headlines together and research the underlying story
- Focus on the 5-8 most newsworthy topics
- Skip trivial or duplicate items
- For each topic, provide a short research brief (3-5 bullet points of facts)
- Include source URLs where applicable
- Output everything as clean markdown

## Headlines

PROMPT_END
)

RESEARCH_PROMPT="${RESEARCH_PROMPT}
${HEADLINES}"

echo "$RESEARCH_PROMPT" | claude -p --model sonnet --allowedTools "WebSearch" > "$RESEARCH_FILE" 2>/dev/null

if [ ! -s "$RESEARCH_FILE" ]; then
  echo "WARNING: Research step returned empty. Continuing without research." >&2
  echo "No research data available." > "$RESEARCH_FILE"
fi

echo "Research complete: $RESEARCH_FILE ($(wc -w < "$RESEARCH_FILE") words)"
