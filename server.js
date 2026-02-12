const express = require('express');
const path = require('path');

const PORT = process.env.PORT || 18796;
const SITE_DIR = path.join(__dirname, 'site', 'public');

const app = express();

app.use(express.static(SITE_DIR, {
  maxAge: '5m',
  etag: true,
}));

// Fallback to 404.html for Hugo's custom 404 page
app.use((req, res) => {
  res.status(404).sendFile(path.join(SITE_DIR, '404.html'), (err) => {
    if (err) res.status(404).send('Not found');
  });
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`Morning Digest serving on http://127.0.0.1:${PORT}`);
});
