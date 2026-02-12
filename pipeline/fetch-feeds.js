#!/usr/bin/env node

const Parser = require('rss-parser');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const sources = JSON.parse(fs.readFileSync(path.join(__dirname, 'sources.json'), 'utf8'));
const parser = new Parser({
  timeout: 10000,
  headers: {
    'User-Agent': 'MorningDigest/1.0 (+https://news.btctx.us)',
  },
});

const LOOKBACK_MS = sources.lookbackHours * 60 * 60 * 1000;
const FEED_TIMEOUT_MS = 12000;

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timeout after ${ms}ms`)), ms);
    promise.then(
      (val) => { clearTimeout(timer); resolve(val); },
      (err) => { clearTimeout(timer); reject(err); }
    );
  });
}

async function fetchFeed(feed) {
  try {
    const result = await withTimeout(parser.parseURL(feed.url), FEED_TIMEOUT_MS, feed.name);
    const cutoff = new Date(Date.now() - LOOKBACK_MS);

    const items = (result.items || [])
      .map((item) => {
        const pubDate = item.pubDate || item.isoDate || item.published;
        return {
          title: item.title || '(untitled)',
          link: item.link || '',
          pubDate: pubDate || null,
          description: (item.contentSnippet || item.content || item.summary || '').slice(0, 1000),
          source: feed.name,
          category: feed.category,
          type: feed.type,
        };
      })
      .filter((item) => {
        if (!item.pubDate) return true;
        return new Date(item.pubDate) >= cutoff;
      });

    console.error(`  ✓ ${feed.name}: ${items.length} items (of ${result.items?.length || 0} total)`);
    return items;
  } catch (err) {
    console.error(`  ✗ ${feed.name}: ${err.message}`);
    return [];
  }
}

async function main() {
  const today = new Date().toISOString().slice(0, 10);
  console.error(`Fetching feeds for ${today} (lookback: ${sources.lookbackHours}h)`);

  const results = await Promise.allSettled(
    sources.feeds.map((feed) => fetchFeed(feed))
  );

  const allItems = results
    .filter((r) => r.status === 'fulfilled')
    .flatMap((r) => r.value)
    .sort((a, b) => {
      if (!a.pubDate) return 1;
      if (!b.pubDate) return -1;
      return new Date(b.pubDate) - new Date(a.pubDate);
    });

  const output = {
    date: today,
    fetchedAt: new Date().toISOString(),
    lookbackHours: sources.lookbackHours,
    totalItems: allItems.length,
    bySource: {},
    items: allItems,
  };

  for (const item of allItems) {
    output.bySource[item.source] = (output.bySource[item.source] || 0) + 1;
  }

  const rawDir = path.join(ROOT, 'raw');
  fs.mkdirSync(rawDir, { recursive: true });
  const outPath = path.join(rawDir, `${today}.json`);
  fs.writeFileSync(outPath, JSON.stringify(output, null, 2));

  console.error(`\nTotal: ${allItems.length} items from ${Object.keys(output.bySource).length} sources`);
  console.error(`Written to: ${outPath}`);
}

main().then(() => {
  process.exit(0);
}).catch((err) => {
  console.error(`Fatal: ${err.message}`);
  process.exit(1);
});
