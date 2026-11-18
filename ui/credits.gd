## The credits page: the menu music with the attributions its licences ask for (the wording is
## assets/music/CREDITS.md's), the game's own sounds, the icon set, the typeface and the engine.
extends Control

const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")

## Per work: the title line, then the lines under it. The music's are exactly those of
## assets/music/CREDITS.md, "Attribution to show in the game".
const MUSIC: Array = [
	[
		"\"Drifting Through the Nebula (Ambient)\" by HitCtrl",
		"https://opengameart.org/content/drifting-through-the-nebula-ambient",
		"Licensed under CC BY 3.0: https://creativecommons.org/licenses/by/3.0/",
	],
	[
		"\"Chillwave Nightdrive\" by Bogart VGM (https://www.facebook.com/BogartVGM/)",
		"https://opengameart.org/content/chillwave-nightdrive",
		"Licensed under CC BY 3.0: https://creativecommons.org/licenses/by/3.0/",
	],
	[
		"\"Observing The Star\" by yd",
		"https://opengameart.org/content/another-space-background-track (CC0)",
	],
	[
		"\"Calm Ambient 1 (Synthwave 4k)\" by The Cynic Project / cynicmusic.com / pixelsphere.org",
		"https://opengameart.org/content/calm-ambient-1-synthwave-4k (CC0)",
	],
	[
		"\"Exploration Theme\": music by Cleyton Kauffman, https://soundcloud.com/cleytonkauffman",
		"https://opengameart.org/content/exploration-theme (CC0)",
	],
]
const ICONS: Array = [
	[
		"Lucide icons by Lucide Icons and Contributors",
		"https://lucide.dev",
		"Licensed under the ISC License; the icons derived from Feather (by Cole Bemis) under the MIT License",
	],
	[
		"Lucide Icons for Godot by Rodrigo Rufino",
		"https://github.com/Rodrigoalvesr/lucide-godot",
		"Licensed under the MIT License",
	],
]
const TYPE: Array = [
	[
		"Outfit by The Outfit Project Authors",
		"https://github.com/Outfitio/Outfit-Fonts",
		"Licensed under the SIL Open Font License, Version 1.1",
	],
]
const ENGINE: Array = [
	[
		"Godot Engine by Juan Linietsky, Ariel Manzur and the Godot Engine contributors",
		"https://godotengine.org",
		"Licensed under the MIT License",
	],
]
const SOUNDS_NOTE := ("The sounds of cuts, misses and bombs are Kenbu's own, made in the game from "
	+ "sine waves and filtered noise; nothing is sampled or recorded.")
const MAPS_NOTE := ("Songs and maps are the work of their artists and mappers. Kenbu reads the "
	+ "community map format from your own songs folder and downloads maps from BeatSaver "
	+ "(https://beatsaver.com) at your request; it never redistributes them.")


func _ready() -> void:
	theme = Style.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(centre)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 1180
	column.add_theme_constant_override("separation", 14)
	centre.add_child(column)

	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 16)
	heading.add_child(Icons.rect("heart", 40, Style.CORE))
	heading.add_child(Style.label("Credits", &"Title"))
	column.add_child(heading)
	var about := Style.label("Kenbu is an original rhythm game. It is built on the work below, "
		+ "with thanks.", &"Lead")
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(about)

	column.add_child(_section("Menu music", "audio-lines", MUSIC))
	var sounds := _card("Game sounds", "audio-waveform")
	var sounds_note := Style.label(SOUNDS_NOTE, &"Dim")
	sounds_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sounds.add_child(sounds_note)
	column.add_child(sounds.get_parent())
	column.add_child(_section("Icons", "shapes", ICONS))
	column.add_child(_section("Typeface", "type", TYPE))
	column.add_child(_section("Engine", "cpu", ENGINE))
	var maps := _card("Songs and maps", "disc-3")
	var note := Style.label(MAPS_NOTE, &"Dim")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	maps.add_child(note)
	column.add_child(maps.get_parent())


## Every line the page shows, top to bottom.
func lines() -> PackedStringArray:
	var out := PackedStringArray()
	for node in find_children("*", "Label", true, false):
		out.append((node as Label).text)
	return out


func _section(title: String, icon: String, entries: Array) -> Control:
	var stack := _card(title, icon)
	for entry: Array in entries:
		var block := VBoxContainer.new()
		block.add_theme_constant_override("separation", 0)
		for i in entry.size():
			var text := Style.label(String(entry[i]), &"Strong" if i == 0 else &"Muted")
			text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			block.add_child(text)
		stack.add_child(block)
	return stack.get_parent()


## A glass card with a captioned heading; returns the stack inside it.
func _card(title: String, icon: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = &"Glass"
	var padded := Style.theme().get_stylebox(&"panel", &"Glass").duplicate() as StyleBoxFlat
	padded.set_content_margin_all(22)
	padded.content_margin_left = 26
	padded.content_margin_right = 26
	card.add_theme_stylebox_override("panel", padded)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	card.add_child(stack)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.add_child(Icons.rect(icon, 28, Style.VEIL))
	head.add_child(Style.caption(title))
	stack.add_child(head)
	return stack
