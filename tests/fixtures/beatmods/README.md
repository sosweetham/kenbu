# BeatMods API answers for offline tests

Real answers of https://beatmods.com/api/v3 recorded on 2026-11-17 with `User-Agent: Kenbu/0.1`,
re-serialised without whitespace. They are catalogue metadata only; no model file and no preview
picture is stored here (tests/beatmods_test.gd makes its pictures itself and reads model files from
the local mirror, outside the repository). Every asset's `description` is emptied (it is the
author's own writing and no check reads it), `statusHistory` is emptied, and `uploader` keeps only
`id`, `username` and `displayName`.

The recordings use small pages (`limit` 3 or 4) to stay small; the client asks for `limit=100`, and
the test serves these files for those requests with `total` cut to what the files hold.

| File | Request |
|---|---|
| `saber_saber_page1.json` | `GET /api/v3/assets?type=saber_saber&page=1&limit=4` |
| `saber_whacker_page1.json` | `GET /api/v3/assets?type=saber_whacker&page=1&limit=3` |
| `note_bloq_page1.json` | `GET /api/v3/assets?type=note_bloq&page=1&limit=4` |
| `note_bloq_page2.json` | `GET /api/v3/assets?type=note_bloq&page=2&limit=4` |
| `wall_pixie_page1.json` | `GET /api/v3/assets?type=wall_pixie&page=1&limit=100` (nothing is published) |
| `avatar_avatar_page1.json` | `GET /api/v3/assets?type=avatar_avatar&page=1&limit=3` |
| `platform_plat_page1.json` | `GET /api/v3/assets?type=platform_plat&page=1&limit=3` |
| `bad_page.json` | `GET /api/v3/assets?type=note_bloq&page=0&limit=4` (HTTP 400: pages start at 1) |
