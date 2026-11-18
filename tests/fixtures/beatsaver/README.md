# BeatSaver API answers for offline tests

Real answers of https://api.beatsaver.com recorded on 2026-11-16 with `User-Agent: Kenbu/0.1`,
re-serialised without whitespace. They are metadata only; no map, cover or audio is stored here.
Every map's `description` is emptied: it is the mapper's own writing, which BeatSaver's terms do
not let others republish, and no check reads it.

| File | Request |
|---|---|
| `search_text.json` | `GET /search/text/0?q=camellia&order=Relevance` |
| `search_curated.json` | `GET /search/text/0?q=&order=Curated&pageSize=12` |
| `search_filtered.json` | `GET /search/text/0?q=&order=Rating&pageSize=4&noodle=true&minNps=3&maxNps=8&minDuration=90&maxDuration=240` |
| `latest.json` | `GET /maps/latest?pageSize=3&sort=FIRST_PUBLISHED` (no `info` block) |
| `map_1185.json` | `GET /maps/id/1185` |
| `map_missing.json` | `GET /maps/id/zzzzzzzz` (HTTP 404) |
