# Menu asset credits

Third-party assets the menus use. Each is bundled unmodified with its licence file, and
each is named on the in-game credits screen (`ui/credits.gd`).

| Asset | Where | Author | Licence |
| ----- | ----- | ------ | ------- |
| Outfit (variable font, `Outfit[wght].ttf`) | `assets/ui/fonts/Outfit.ttf` | The Outfit Project Authors | SIL Open Font License 1.1 (`assets/ui/fonts/OFL.txt`) |
| Lucide icons 1.73.0 (SVG) | `addons/lucide/icons/` | Lucide Icons and Contributors; some icons derived from Feather by Cole Bemis | ISC, and MIT for the Feather-derived icons (`addons/lucide/icons/LICENSE`) |
| Lucide Icons for Godot 1.1.0 (its layout only; no code bundled) | `addons/lucide/` | Rodrigo Rufino | MIT (`addons/lucide/LICENSE`) |

## Outfit

- **Source:** https://github.com/google/fonts/tree/main/ofl/outfit (file `Outfit[wght].ttf`,
  renamed `Outfit.ttf`); upstream https://github.com/Outfitio/Outfit-Fonts
- **Downloaded:** 2026-11-17
- **Use:** every menu text (`ui/style.gd` reads the file at runtime; the system UI font is the
  fallback for glyphs Outfit lacks).

## Lucide icons

- **Source:** https://github.com/lucide-icons/lucide/releases/tag/1.73.0
  (`lucide-icons-1.73.0.zip`, the SVG files only), the release the addon's own installer
  fetches; site https://lucide.dev
- **Downloaded:** 2026-11-17
- **Use:** every menu icon. `ui/icons.gd` rasterises the SVG files at runtime
  (`Image.load_svg_from_string`), so they need no editor import; `icons/.gdignore` keeps the
  editor from importing all 2055 of them.

## Lucide Icons for Godot

- **Source:** https://godotengine.org/asset-library/asset/5047,
  https://github.com/Rodrigoalvesr/lucide-godot at commit
  `bfc6e57430c67ce59d788aa0c674559aeb20fe4e`
- **Downloaded:** 2026-11-17
- **Use:** the addon's layout (`addons/lucide/icons/<name>.svg`) and its way of rasterising an
  icon. Its scripts (an editor plugin declaring global classes, which Kenbu's rules forbid, and
  downloading icon releases from GitHub) are not bundled; its licence stays with the layout.
