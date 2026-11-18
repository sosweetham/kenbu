## The models page: browse BeatMods' sabers, notes, walls, avatars and platforms, see a model's
## preview (animated when BeatMods has a GIF), get it, and pick which installed model each kind
## uses. A tab per kind; search, sort and tag filters work on the kind's whole listing, which
## content/beatmods.gd keeps for a day, so they answer at once. "Installed" shows what is on this
## Mac and works offline. Everything is a visible, pointer-sized target, the grid scrolls with the
## wheel (a headset thumbstick arrives as wheel steps, see xr/panel.gd) and the on-panel keyboard
## types into the search field in VR. All network and disk work goes through the client; this
## script only shows what its signals report.
extends Control

## A kind's choice changed; `md5` is "" for Kenbu's own model.
signal model_selected(kind: String, md5: String)

const Client = preload("res://content/beatmods.gd")
const Card = preload("res://ui/models_card.gd")
const Details = preload("res://ui/models_details.gd")
const Preview = preload("res://ui/models_preview.gd")
const Keyboard = preload("res://ui/keyboard.gd")
const Style = preload("res://ui/style.gd")
const Icons = preload("res://ui/icons.gd")

const KIND_TITLES: Dictionary = {
	"saber": "Sabers", "note": "Notes", "wall": "Walls", "avatar": "Avatars", "platform": "Platforms",
}
## Singular and plural, for counts.
const KIND_NOUNS: Dictionary = {
	"saber": ["saber", "sabers"], "note": ["note set", "note sets"], "wall": ["wall", "walls"],
	"avatar": ["avatar", "avatars"], "platform": ["platform", "platforms"],
}
const SORTS: PackedStringArray = ["newest", "name", "author", "smallest", "largest"]
const SORT_LABELS: PackedStringArray = ["Newest", "Name", "Author", "Smallest", "Largest"]
## The tags offered as filters per kind, most telling first (the catalogue's spelling;
## ui/models_details.gd's TAG_LABELS names them).
const KIND_TAGS: Dictionary = {
	"saber": ["CustomColors", "CustomTrails", "Animations", "Particles", "Thin", "Large", "Sword",
		"Reactive", "DynamicBones", "Acc", "Simple"],
	"note": ["CustomColors", "CustomArrows", "CustomBombs", "Animations", "Acc", "Simple"],
	"wall": [],
	"avatar": ["FBT", "DynamicBones", "Cloth", "Animations", "Anime", "Simple"],
	"platform": ["Animations", "Particles", "CustomColors", "Reactive", "Simple"],
}
const SOON_TEXT: Dictionary = {
	"platform": "Kenbu can't build BeatMods platforms yet. You can install them now and they'll be ready the day it can.",
}
const COLUMNS: int = 4
## Cards made at a time; more are added as the grid is scrolled.
const PAGE: int = 40
const PREVIEW_MARGIN: float = 400.0
const MORE_MARGIN: float = 500.0
const TYPING_PAUSE: float = 0.3
## Preview frames kept as textures before the least recently shown are let go.
const FRAME_BUDGET: int = 420
const OWN_KEY: String = "own"

var _client: Client = null
var _kind: String = "saber"
var _installed_view: bool = false
var _query: String = ""
var _sort: String = "newest"
## Kind -> the tags its filter asks for.
var _tags: Dictionary = {}
var _open_only: bool = false
var _nsfw: bool = false
var _xr: bool = false
## What matches the search and filters, in order; cards exist for the first `_built`.
var _matching: Array[Dictionary] = []
var _built: int = 0
## Models that would match too but are tagged NSFW, which the filters hide.
var _hidden_nsfw: int = 0
## Card key -> Card.
var _cards: Dictionary = {}
var _selected_key: String = ""
## "<kind>|<view>" -> the card key last picked there.
var _remembered: Dictionary = {}
## Asset id -> [Card.State, fraction, message] of a download this run started or saw.
var _transfers: Dictionary = {}
var _failed_kinds: Dictionary = {}
## Preview key -> Array[Texture2D] / PackedFloat32Array, and the keys from least to most recent.
var _textures: Dictionary = {}
var _delays: Dictionary = {}
var _texture_order: PackedStringArray = PackedStringArray()
var _frames_held: int = 0

var _layout: HBoxContainer
var _kind_buttons: Dictionary = {}
var _installed_button: Button
var _field: LineEdit
var _keyboard_button: Button
var _filters_button: Button
var _filters_panel: PanelContainer
var _filter_flow: HFlowContainer
var _tag_buttons: Dictionary = {}
var _open_button: Button
var _nsfw_button: Button
var _sort_row: Control
var _sort_buttons: Array[Button] = []
var _status: Label
## Under the count: what it leaves out, or why the list may be old.
var _status_note: Label
var _banner: PanelContainer
var _banner_text: Label
var _scroll: ScrollContainer
var _grid: GridContainer
var _end: Label
var _notice: VBoxContainer
var _notice_icon: TextureRect
var _notice_title: Label
var _notice_text: Label
var _notice_button: Button
var _details: Details
var _keyboard: Keyboard
var _typing: Timer


func _init() -> void:
	theme = _theme()
	_build()


func _ready() -> void:
	visibility_changed.connect(_on_visibility_changed)
	_load_when_shown()


## `client` is a content/beatmods.gd node; it is added under the tab when it has no parent yet.
func setup(client: Node) -> void:
	var next := client as Client
	if next == null:
		push_error("The models page needs a content/beatmods.gd client")
		return
	if _client != null and _client != next:
		_listen(_client, false)
	_client = next
	if _client.get_parent() == null:
		add_child(_client)
	_listen(_client, true)
	_mark_installed_button()
	_load_when_shown()


## In VR the keyboard opens whenever the search field takes the focus or is pressed, and links to
## the web are hidden. ui/menu.gd passes on what main.gd tells it.
func set_xr(xr: bool) -> void:
	_xr = xr
	_details.set_desktop_links(not xr)


## `kind` is one of content/beatmods.gd's KINDS.
func show_kind(kind: String) -> void:
	if not Client.KINDS.has(kind) or kind == _kind:
		return
	_remember()
	_kind = kind
	_mark_kinds()
	_build_tag_filters()
	_mark_installed_button()
	_selected_key = String(_remembered.get(_view_key(), ""))
	_show_view()


func kind() -> String:
	return _kind


## The installed models of the kind instead of BeatMods' listing.
func show_installed(on: bool) -> void:
	_installed_button.set_pressed_no_signal(on)
	if on == _installed_view:
		return
	_remember()
	_installed_view = on
	_selected_key = String(_remembered.get(_view_key(), ""))
	_show_view()


func is_installed_view() -> bool:
	return _installed_view


func set_query(text: String) -> void:
	_field.text = text
	_field.caret_column = text.length()
	search_now()


func query() -> String:
	return _query


## Applies what the search field holds.
func search_now() -> void:
	_typing.stop()
	_query = _field.text.strip_edges()
	_refresh(true)


## `sort` is one of SORTS.
func set_sort(sort: String) -> void:
	if not SORTS.has(sort) or sort == _sort:
		return
	_sort = sort
	_mark_sorts()
	_refresh(true)


func sort() -> String:
	return _sort


## Asks for (or stops asking for) a tag of the kind's KIND_TAGS.
func set_tag(tag: String, on: bool) -> void:
	var wanted: PackedStringArray = _tags.get(_kind, PackedStringArray())
	if on and not wanted.has(tag):
		wanted.append(tag)
	elif not on and wanted.has(tag):
		wanted.remove_at(wanted.find(tag))
	_tags[_kind] = wanted
	_mark_filters()
	_refresh(true)


func tags() -> PackedStringArray:
	return _tags.get(_kind, PackedStringArray())


## Only models under a Creative Commons licence.
func set_open_only(on: bool) -> void:
	_open_only = on
	_mark_filters()
	_refresh(true)


## Models tagged NSFW are left out unless this is on.
func set_nsfw(on: bool) -> void:
	_nsfw = on
	_mark_filters()
	_refresh(true)


func show_filters(shown: bool) -> void:
	_filters_panel.visible = shown
	_filters_button.set_pressed_no_signal(shown)


func show_keyboard(shown: bool) -> void:
	var closing := _keyboard.visible and not shown
	_keyboard.visible = shown
	_keyboard_button.set_pressed_no_signal(shown)
	_fit_keyboard.call_deferred()
	if shown and not _field.has_focus():
		_field.grab_focus()
		_field.caret_column = _field.text.length()
	if closing and _field.text.strip_edges() != _query:
		search_now()


func keyboard() -> Keyboard:
	return _keyboard


func search_field() -> LineEdit:
	return _field


func details() -> Details:
	return _details


func cards() -> Array[Card]:
	var out: Array[Card] = []
	for child in _grid.get_children():
		if child is Card and not child.is_queued_for_deletion():
			out.append(child as Card)
	return out


## The card of a listing asset (by id) or an installed entry (by MD5), or null.
func card_of(asset: Dictionary) -> Card:
	return _cards.get(_key(asset)) as Card


## The card of Kenbu's own model in the installed view, or null.
func own_card() -> Card:
	return _cards.get(OWN_KEY) as Card


func select_card(picked: Card) -> void:
	if picked == null:
		return
	_select(_key_of_card(picked))


## How many models match the search and filters (cards exist for the first of them).
func matching_count() -> int:
	return _matching.size()


## The count, and the note under it after "  ·  " when there is one.
func status_text() -> String:
	return _status.text if not _status_note.visible else "%s  ·  %s" % [_status.text, _status_note.text]


func notice_text() -> String:
	return _notice_title.text if _notice.visible else ""


func banner_text() -> String:
	return _banner_text.text if _banner.visible else ""


## Starts the download of the picked model, as the details panel's Get button does.
func get_selected() -> void:
	var asset := _details.asset()
	if _client == null or asset.is_empty() or int(asset.get("id", 0)) <= 0:
		return
	_transfers[int(asset["id"])] = [Card.State.WAITING, 0.0, ""]
	_show_transfer(int(asset["id"]))
	_client.download(asset)


func use_selected() -> void:
	var asset := _details.asset()
	var md5 := _md5(asset)
	if _client == null or md5.is_empty():
		return
	_client.select(_kind, md5)
	model_selected.emit(_kind, md5)


func use_own() -> void:
	if _client == null:
		return
	_client.select(_kind, "")
	model_selected.emit(_kind, "")


func delete_selected() -> void:
	var md5 := _md5(_details.asset())
	if _client == null or md5.is_empty():
		return
	var was_used := _client.selected(_kind) == md5
	_client.uninstall(md5)
	if was_used:
		model_selected.emit(_kind, "")


func _listen(client: Client, on: bool) -> void:
	var links: Array = [
		[client.listing, _on_listing], [client.listing_failed, _on_listing_failed],
		[client.preview_ready, _on_preview_ready],
		[client.download_progress, _on_download_progress],
		[client.import_started, _on_import_started],
		[client.install_finished, _on_install_finished],
		[client.install_failed, _on_install_failed],
		[client.installed_changed, _on_installed_changed],
		[client.selection_changed, _on_selection_changed],
	]
	for link: Array in links:
		var sent: Signal = link[0]
		var handler: Callable = link[1]
		if on and not sent.is_connected(handler):
			sent.connect(handler)
		elif not on and sent.is_connected(handler):
			sent.disconnect(handler)


func _load_when_shown() -> void:
	if _client != null and is_inside_tree() and is_visible_in_tree():
		_show_view()


func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_load_when_shown()
	else:
		_typing.stop()


func _view_key() -> String:
	return "%s|%s" % [_kind, "installed" if _installed_view else "browse"]


func _remember() -> void:
	_remembered[_view_key()] = _selected_key


## Shows the current kind and view from scratch: asks for the listing when browsing.
func _show_view() -> void:
	if _client == null:
		return
	_banner.visible = not Client.is_usable(_kind)
	_banner_text.text = String(SOON_TEXT.get(_kind, ""))
	_sort_row.visible = true
	if not _installed_view:
		_failed_kinds.erase(_kind)
		_client.list(_kind)
	_refresh(true)


## Works out what matches and rebuilds the cards; `from_top` also scrolls back to the start.
func _refresh(from_top: bool) -> void:
	if _client == null:
		return
	var source: Array[Dictionary] = _client.installed(_kind) if _installed_view else _client.assets(_kind)
	var wanted: PackedStringArray = _tags.get(_kind, PackedStringArray())
	var found: Array[Dictionary] = []
	_hidden_nsfw = 0
	for asset in source:
		var searched := _searched(asset)
		if Client.matches(searched, _query, wanted, _open_only, _nsfw):
			found.append(asset)
		elif not _nsfw and Client.matches(searched, _query, wanted, _open_only, true):
			_hidden_nsfw += 1
	if not _installed_view or _sort != "newest":
		Client.sort_assets(found, _sort)
	_matching = found
	var keep := 0 if from_top else _scroll.scroll_vertical
	_rebuild_cards()
	_scroll.set_deferred("scroll_vertical", keep)
	_show_state()


## What a search looks through for `asset`: a listing asset that is installed also answers to the
## author in its file, which its card shows.
func _searched(asset: Dictionary) -> Dictionary:
	if _installed_view or _query.is_empty():
		return asset
	var author := String(_client.entry(_md5(asset)).get("descriptor_author", ""))
	if author.is_empty():
		return asset
	var probe := asset.duplicate()
	probe["descriptor_author"] = author
	return probe


func _rebuild_cards() -> void:
	if _client != null:
		_client.cancel_pending_previews()
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()
	_built = 0
	if _installed_view and Client.is_usable(_kind) and _query.is_empty() and tags().is_empty():
		var words: Dictionary = Details.KIND_TEXT[_kind]
		var own := Card.new({}, Details.KIND_ICONS[_kind], String(words["own"]), "Made for Kenbu")
		own.preview().show_emblem(_kind)
		_add_card(OWN_KEY, own)
	_add_cards(PAGE)
	if not _cards.has(_selected_key):
		_selected_key = ""
		if _installed_view and _cards.has(_key_for_md5(_client.selected(_kind))):
			_selected_key = _key_for_md5(_client.selected(_kind))
		elif not _cards.is_empty():
			_selected_key = String(_cards.keys()[0])
	_mark_selected()
	_show_details()
	_fetch_previews.call_deferred()


func _add_cards(count: int) -> void:
	var until := mini(_built + count, _matching.size())
	while _built < until:
		var asset := _matching[_built]
		_built += 1
		var key := _key(asset)
		if _cards.has(key):
			continue
		_add_card(key, Card.new(asset, Details.KIND_ICONS[_kind], "", _byline(asset)))
	_end.visible = _built >= _matching.size() and _built > PAGE
	_end.text = "That's all %s." % _count_text(_matching.size())


func _add_card(key: String, made: Card) -> void:
	made.pressed.connect(_select.bind(key))
	_grid.add_child(made)
	_cards[key] = made
	_set_card_state(key, made)
	var preview_key := Client.preview_key(made.asset)
	if _textures.has(preview_key):
		made.preview().set_frames(_textures[preview_key], _delays[preview_key])
		made.preview_requested = true


func _byline(asset: Dictionary) -> String:
	var author := Client.author_text(asset)
	return author if not author.is_empty() else "Author not recorded"


func _key(asset: Dictionary) -> String:
	if asset.is_empty():
		return OWN_KEY
	if _installed_view:
		return _key_for_md5(_md5(asset))
	return "id:%d" % int(asset.get("id", 0))


static func _key_for_md5(md5: String) -> String:
	return OWN_KEY if md5.is_empty() else "md5:" + md5


func _key_of_card(made: Card) -> String:
	for key: String in _cards:
		if _cards[key] == made:
			return key
	return ""


## The MD5 an asset is installed under: an entry's own, or a listing asset's file hash.
static func _md5(asset: Dictionary) -> String:
	var md5 := String(asset.get("md5", ""))
	return md5 if not md5.is_empty() else String(asset.get("file_hash", ""))


func _select(key: String) -> void:
	if not _cards.has(key):
		return
	_selected_key = key
	_mark_selected()
	_show_details()


func _mark_selected() -> void:
	for key: String in _cards:
		(_cards[key] as Card).set_selected(key == _selected_key)


func _card_state(asset: Dictionary) -> Array:
	if asset.is_empty():
		var own_used := _client.selected(_kind).is_empty() and Client.is_usable(_kind)
		return [Card.State.IN_USE if own_used else Card.State.IDLE, 0.0, ""]
	var id := int(asset.get("id", 0))
	var md5 := _md5(asset)
	if _client.entry(md5).is_empty():
		if _transfers.has(id):
			return _transfers[id]
		if _client.is_downloading(id):
			return [Card.State.WAITING, 0.0, ""]
		return [Card.State.IDLE, 0.0, ""]
	if _client.selected(_kind) == md5:
		return [Card.State.IN_USE, 0.0, ""]
	return [Card.State.INSTALLED, 0.0, ""]


func _set_card_state(key: String, made: Card) -> void:
	var found := _card_state(made.asset)
	var state: Card.State = found[0]
	# In the installed view every card is installed; only the one in use says so.
	if _installed_view and state == Card.State.INSTALLED:
		state = Card.State.IDLE
	made.set_state(state, float(found[1]))
	# Once a model is installed its file names the author, as the details panel then shows.
	if not made.asset.is_empty():
		var installed := _client.entry(_md5(made.asset))
		made.set_byline(_byline(installed if not installed.is_empty() else made.asset))


func _mark_card_states() -> void:
	for key: String in _cards:
		_set_card_state(key, _cards[key])


func _details_status(asset: Dictionary) -> Array:
	var found := _card_state(asset)
	var state: Card.State = found[0]
	if asset.is_empty():
		return [Details.Status.OWN_IN_USE if state == Card.State.IN_USE else Details.Status.OWN, 0.0, ""]
	match state:
		Card.State.WAITING:
			return [Details.Status.WAITING, 0.0, ""]
		Card.State.DOWNLOADING:
			return [Details.Status.DOWNLOADING, found[1], ""]
		Card.State.CONVERTING:
			return [Details.Status.CONVERTING, 0.0, ""]
		Card.State.FAILED:
			return [Details.Status.FAILED, 0.0, found[2]]
		Card.State.IN_USE:
			return [Details.Status.IN_USE, 0.0, ""]
		Card.State.INSTALLED:
			return [Details.Status.INSTALLED if Client.is_usable(_kind) else Details.Status.SOON, 0.0, ""]
	return [Details.Status.AVAILABLE, 0.0, ""]


func _show_details() -> void:
	var picked := _cards.get(_selected_key) as Card
	if picked == null:
		_details.show_nothing(_kind)
		return
	# Once installed, a listing asset is shown as its entry: the author in the file is known then.
	var asset := picked.asset
	var installed: Dictionary = _client.entry(_md5(asset)) if not asset.is_empty() else {}
	var status := _details_status(asset)
	_details.show_model(installed if not installed.is_empty() else asset, _kind, status[0])
	_details.set_status(status[0], float(status[1]), String(status[2]))
	var shown := _details.asset()
	if shown.is_empty():
		_details.preview().show_emblem(_kind)
	var preview_key := Client.preview_key(shown)
	if _textures.has(preview_key):
		_touch(preview_key)
		_details.preview().set_frames(_textures[preview_key], _delays[preview_key])
	elif not shown.is_empty():
		var listed := Client.preview_key(asset)
		if _textures.has(listed):
			_details.preview().set_frames(_textures[listed], _delays[listed])
		_client.fetch_preview(shown)


func _show_transfer(id: int) -> void:
	var key := "id:%d" % id
	if not _installed_view and _cards.has(key):
		_set_card_state(key, _cards[key])
	if int(_details.asset().get("id", 0)) == id and _details.title() != "":
		var status := _details_status(_details.asset())
		_details.set_status(status[0], float(status[1]), String(status[2]))


## The count beside the sort chips with its note, and the notice shown instead of an empty grid. The
## count leaves out what the NSFW filter hides and the note says how many that is; with it the count
## adds up to BeatMods' listing, where a `.whacker` twin is its `.saber` (content/beatmods.gd
## `without_twins`).
func _show_state() -> void:
	var total := _offered_count(_client.installed(_kind) if _installed_view else _client.assets(_kind))
	var loading := not _installed_view and _client.is_listing(_kind)
	var failed := String(_failed_kinds.get(_kind, ""))
	if _matching.size() == total:
		_status.text = _count_text(total)
	else:
		_status.text = "%s of %s" % [Style.digits(_matching.size()), _count_text(total)]
	_status_note.text = ""
	if _installed_view:
		_status.text += " installed"
	elif loading and total > 0 and _client.listing_time(_kind) == 0:
		_status.text = "%s so far" % _count_text(total)
	elif not failed.is_empty() and total > 0:
		_status_note.text = "saved list, BeatMods didn't answer"
	if _hidden_nsfw > 0 and failed.is_empty():
		_status_note.text = "%s NSFW hidden" % Style.digits(_hidden_nsfw)
	_status_note.visible = not _status_note.text.is_empty()
	if not _cards.is_empty():
		_hide_notice()
		return
	var nouns: Array = KIND_NOUNS[_kind]
	if _installed_view:
		_show_notice("package-open", "No %s installed" % String(nouns[1]),
			"Get some from BeatMods and they'll be here, ready without the internet.", "Browse BeatMods")
	elif total > 0:
		_show_notice("search-x", "No %s match" % String(nouns[1]),
			"Try another spelling, fewer words or fewer filters.", "")
	elif loading:
		_show_notice("search", "Reading BeatMods' catalogue", "", "")
	elif not failed.is_empty():
		_show_notice("wifi-off", "No answer from BeatMods", failed, "Try again")
	elif _client.listing_time(_kind) > 0:
		_show_notice("package-search", "BeatMods has no %s yet" % String(nouns[1]),
			"Nobody has published any. When someone does, they'll show up here.", "Look again")
	else:
		_show_notice("search", "Reading BeatMods' catalogue", "", "")


## The models of `found` the page offers at all: those tagged NSFW count only while shown.
func _offered_count(found: Array[Dictionary]) -> int:
	if _nsfw:
		return found.size()
	var count := 0
	for asset in found:
		if not (asset.get("tags", PackedStringArray()) as PackedStringArray).has(Client.NSFW_TAG):
			count += 1
	return count


func _count_text(count: int) -> String:
	var nouns: Array = KIND_NOUNS[_kind]
	return "%s %s" % [Style.digits(count), String(nouns[0] if count == 1 else nouns[1])]


func _hide_notice() -> void:
	_notice.visible = false
	_scroll.visible = true


func _show_notice(icon: String, title: String, text: String, action: String) -> void:
	_notice.visible = true
	_scroll.visible = false
	_notice_icon.texture = Icons.texture(icon, 72, 1.5)
	_notice_title.text = title
	_notice_text.text = text
	_notice_text.visible = not text.is_empty()
	_notice_button.text = action
	_notice_button.visible = not action.is_empty()


func _on_notice_pressed() -> void:
	if _installed_view:
		show_installed(false)
	else:
		_failed_kinds.erase(_kind)
		_client.list(_kind, true)
		_show_state()


func _on_listing(kind: String, _assets: Array, complete: bool) -> void:
	if complete:
		_failed_kinds.erase(kind)
	if kind != _kind or _installed_view:
		return
	# Pages of a first fetch arrive one after another: the cards already shown stay as they are.
	if not complete and _built >= PAGE and _sort == "newest":
		_show_state()
		return
	_refresh(false)


func _on_listing_failed(kind: String, message: String) -> void:
	_failed_kinds[kind] = message
	if kind == _kind and not _installed_view:
		_show_state()


## Asks for the previews of cards on or near the visible part of the grid.
func _fetch_previews() -> void:
	if _client == null or not is_visible_in_tree():
		return
	var view := _scroll.get_global_rect().grow(PREVIEW_MARGIN)
	for child in _grid.get_children():
		var made := child as Card
		if made == null or made.preview_requested or made.asset.is_empty():
			continue
		if not view.intersects(made.get_global_rect()):
			continue
		made.preview_requested = true
		_client.fetch_preview(made.asset)


func _on_scrolled(_value: float) -> void:
	var bar := _scroll.get_v_scroll_bar()
	if _built < _matching.size() and bar.value + bar.page >= bar.max_value - MORE_MARGIN:
		_add_cards(PAGE)
		_mark_selected()
	_fetch_previews()


func _on_preview_ready(key: String, frames: Array, delays: PackedFloat32Array) -> void:
	# A second answer for a key replaces the first: an installed model shows its descriptor's cover
	# until its preview has been fetched.
	if _textures.has(key):
		_frames_held -= (_textures[key] as Array).size()
		_texture_order.remove_at(_texture_order.find(key))
	var made: Array[Texture2D] = []
	for frame: Image in frames:
		made.append(ImageTexture.create_from_image(frame))
	_textures[key] = made
	_delays[key] = delays
	_texture_order.append(key)
	_frames_held += made.size()
	_trim_textures(key)
	for child in _grid.get_children():
		var shown := child as Card
		if shown != null and Client.preview_key(shown.asset) == key:
			shown.preview().set_frames(_textures[key], _delays[key])
	if _details.title() != "" and Client.preview_key(_details.asset()) == key:
		_details.preview().set_frames(_textures[key], _delays[key])


func _touch(key: String) -> void:
	var at := _texture_order.find(key)
	if at >= 0 and at != _texture_order.size() - 1:
		_texture_order.remove_at(at)
		_texture_order.append(key)


## Lets go of the least recently shown previews once more than FRAME_BUDGET frames are held. The
## controls showing them keep theirs until they are freed.
func _trim_textures(keep: String) -> void:
	while _frames_held > FRAME_BUDGET and _texture_order.size() > 1:
		var oldest := _texture_order[0]
		if oldest == keep:
			break
		_texture_order.remove_at(0)
		_frames_held -= (_textures[oldest] as Array).size()
		_textures.erase(oldest)
		_delays.erase(oldest)
		for key: String in _cards:
			var made := _cards[key] as Card
			if Client.preview_key(made.asset) == oldest and not made.preview().has_picture():
				made.preview_requested = false


func _on_download_progress(id: int, fraction: float) -> void:
	_transfers[id] = [Card.State.DOWNLOADING, fraction, ""]
	_show_transfer(id)


func _on_import_started(id: int) -> void:
	_transfers[id] = [Card.State.CONVERTING, 1.0, ""]
	_show_transfer(id)


func _on_install_finished(id: int, _entry: Dictionary) -> void:
	_transfers.erase(id)
	if _installed_view:
		return
	_mark_card_states()
	if int(_details.asset().get("id", 0)) == id:
		_show_details()


func _on_install_failed(id: int, message: String) -> void:
	_transfers[id] = [Card.State.FAILED, 0.0, message]
	_show_transfer(id)


func _on_installed_changed() -> void:
	_mark_installed_button()
	if _installed_view:
		_refresh(false)
	else:
		_mark_card_states()
		_show_details()


func _on_selection_changed(kind: String) -> void:
	if kind != _kind:
		return
	_mark_card_states()
	_show_details()


func _on_open_pressed() -> void:
	var url := String(_details.asset().get("page_url", ""))
	if url.begins_with(Client.OFFICIAL_SITE + "/"):
		OS.shell_open(url)


func _on_field_changed(_text: String) -> void:
	_typing.start(TYPING_PAUSE)


func _on_field_submitted(_text: String) -> void:
	search_now()
	show_keyboard(false)


func _on_field_focused() -> void:
	if _xr:
		show_keyboard(true)


## The field keeps the focus when the keyboard's own key closes it, so a press on the field has to
## open it again: focus_entered does not come a second time.
func _on_field_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if _xr and press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		show_keyboard(true)


func _on_keyboard_closed() -> void:
	_keyboard_button.set_pressed_no_signal(false)
	_fit_keyboard.call_deferred()
	if _field.text.strip_edges() != _query:
		search_now()


## The page ends above the keyboard while it shows, so nothing is hidden behind it. Also run when
## the page's minimum size changes: a control that grew past its anchors for a moment (a wrapping
## label asks for a great height until it has its width) does not come back by itself (4.7.2).
func _fit_keyboard() -> void:
	_layout.set_offsets_preset(Control.PRESET_FULL_RECT)
	_layout.offset_bottom = -(_keyboard.size.y + 12.0) if _keyboard.visible else 0.0


func _mark_kinds() -> void:
	for kind: String in _kind_buttons:
		(_kind_buttons[kind] as Button).theme_type_variation = (
			&"TabButtonSelected" if kind == _kind else &"TabButton")


func _mark_sorts() -> void:
	for i in _sort_buttons.size():
		_sort_buttons[i].theme_type_variation = &"TabButtonSelected" if SORTS[i] == _sort else &"TabButton"


func _mark_filters() -> void:
	var wanted := tags()
	for tag: String in _tag_buttons:
		(_tag_buttons[tag] as Button).theme_type_variation = (
			&"TabButtonSelected" if wanted.has(tag) else &"TabButton")
	_open_button.theme_type_variation = &"TabButtonSelected" if _open_only else &"TabButton"
	_nsfw_button.theme_type_variation = &"TabButtonSelected" if _nsfw else &"TabButton"
	var active := wanted.size() + int(_open_only) + int(_nsfw)
	_filters_button.text = "Filters" if active == 0 else "Filters  ·  %d" % active


func _mark_installed_button() -> void:
	var count := _client.installed_count(_kind) if _client != null else 0
	_installed_button.text = "Installed" if count == 0 else "Installed  ·  %d" % count


func _build() -> void:
	_layout = HBoxContainer.new()
	_layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layout.add_theme_constant_override("separation", 20)
	_layout.minimum_size_changed.connect(func() -> void: _fit_keyboard.call_deferred())
	add_child(_layout)
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 12)
	_layout.add_child(page)
	page.add_child(_build_kind_row())
	page.add_child(_build_search_row())
	page.add_child(_build_filters())
	_sort_row = _build_sort_row()
	page.add_child(_sort_row)
	page.add_child(_build_banner())
	page.add_child(_build_results())

	_details = Details.new()
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details.get_pressed.connect(get_selected)
	_details.use_pressed.connect(use_selected)
	_details.default_pressed.connect(use_own)
	_details.delete_pressed.connect(delete_selected)
	_details.open_pressed.connect(_on_open_pressed)
	_layout.add_child(_details)

	_keyboard = Keyboard.new()
	_keyboard.visible = false
	_keyboard.attach(_field)
	_keyboard.closed.connect(_on_keyboard_closed)
	_keyboard.anchor_left = 0.5
	_keyboard.anchor_right = 0.5
	_keyboard.anchor_top = 1.0
	_keyboard.anchor_bottom = 1.0
	_keyboard.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_keyboard.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_keyboard)

	_typing = Timer.new()
	_typing.one_shot = true
	_typing.timeout.connect(search_now)
	add_child(_typing)
	_mark_kinds()
	_mark_sorts()
	_build_tag_filters()


func _build_kind_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for kind in Client.KINDS:
		var chip := Style.icon_button(Details.KIND_ICONS[kind], KIND_TITLES[kind], &"TabButton", 24)
		chip.name = kind.capitalize()
		chip.pressed.connect(show_kind.bind(kind))
		_kind_buttons[kind] = chip
		row.add_child(chip)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_installed_button = Style.icon_button("hard-drive-download", "Installed", &"ModelsToggle", 26)
	_installed_button.toggle_mode = true
	_installed_button.tooltip_text = "The models on this Mac"
	_installed_button.toggled.connect(show_installed)
	row.add_child(_installed_button)
	return row


func _build_search_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_field = LineEdit.new()
	_field.placeholder_text = "Search names, authors and tags"
	_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_field.custom_minimum_size.y = 64
	_field.clear_button_enabled = true
	_field.max_length = 100
	_field.select_all_on_focus = false
	_field.add_theme_font_size_override("font_size", 26)
	for state: String in ["normal", "focus"]:
		var style := (theme.get_stylebox(state, "LineEdit") as StyleBoxFlat).duplicate() as StyleBoxFlat
		style.content_margin_left = 64
		style.set_corner_radius_all(20)
		_field.add_theme_stylebox_override(state, style)
	var glass := Icons.rect("search", 30, Style.TEXT_MUTED)
	glass.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	glass.position = Vector2(20, -15)
	_field.add_child(glass)
	_field.text_changed.connect(_on_field_changed)
	_field.text_submitted.connect(_on_field_submitted)
	_field.focus_entered.connect(_on_field_focused)
	_field.gui_input.connect(_on_field_input)
	row.add_child(_field)
	_keyboard_button = Style.icon_button("keyboard", "", &"ModelsToggle", 30)
	_keyboard_button.custom_minimum_size = Vector2(72, 64)
	_keyboard_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_keyboard_button.toggle_mode = true
	_keyboard_button.focus_mode = Control.FOCUS_NONE
	_keyboard_button.tooltip_text = "On-panel keyboard"
	_keyboard_button.toggled.connect(show_keyboard)
	row.add_child(_keyboard_button)
	_filters_button = Style.icon_button("sliders-horizontal", "Filters", &"ModelsToggle", 26)
	_filters_button.custom_minimum_size.y = 64
	_filters_button.toggle_mode = true
	_filters_button.toggled.connect(show_filters)
	row.add_child(_filters_button)
	return row


func _build_filters() -> Control:
	_filters_panel = PanelContainer.new()
	_filters_panel.visible = false
	_filters_panel.add_theme_stylebox_override("panel",
		Style.box(Style.GLASS, 24, 16, 1, Style.GLASS_EDGE))
	_filter_flow = HFlowContainer.new()
	_filter_flow.add_theme_constant_override("h_separation", 8)
	_filter_flow.add_theme_constant_override("v_separation", 8)
	_filters_panel.add_child(_filter_flow)
	_open_button = Style.icon_button("creative-commons", "Open licence", &"TabButton", 24)
	_open_button.tooltip_text = "Only models under a Creative Commons licence"
	_open_button.pressed.connect(func() -> void: set_open_only(not _open_only))
	_nsfw_button = Style.icon_button("eye-off", "Show NSFW", &"TabButton", 24)
	_nsfw_button.pressed.connect(func() -> void: set_nsfw(not _nsfw))
	return _filters_panel


## The filter chips of the current kind: its tags, then the two that every kind has.
func _build_tag_filters() -> void:
	for child in _filter_flow.get_children():
		_filter_flow.remove_child(child)
		if child != _open_button and child != _nsfw_button:
			child.queue_free()
	_tag_buttons.clear()
	for tag: String in KIND_TAGS[_kind]:
		var chip := Style.button(String(Details.TAG_LABELS.get(tag, tag)), &"TabButton")
		chip.pressed.connect(_on_tag_pressed.bind(tag))
		_tag_buttons[tag] = chip
		_filter_flow.add_child(chip)
	_filter_flow.add_child(_open_button)
	_filter_flow.add_child(_nsfw_button)
	_mark_filters()


func _on_tag_pressed(tag: String) -> void:
	set_tag(tag, not tags().has(tag))


func _build_sort_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var caption := Style.caption("Sort")
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(caption)
	var gap := Control.new()
	gap.custom_minimum_size.x = 4
	row.add_child(gap)
	for i in SORTS.size():
		var chip := Style.button(SORT_LABELS[i], &"TabButton")
		chip.pressed.connect(set_sort.bind(SORTS[i]))
		_sort_buttons.append(chip)
		row.add_child(chip)
	var status := VBoxContainer.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status.add_theme_constant_override("separation", -2)
	_status = Style.line("", &"Dim")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.add_child(_status)
	_status_note = Style.line("", &"Muted")
	_status_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_note.visible = false
	status.add_child(_status_note)
	row.add_child(status)
	return row


func _build_banner() -> Control:
	_banner = PanelContainer.new()
	_banner.visible = false
	var style := Style.box(Color(Style.VEIL, 0.1), 18, 0.0, 1, Color(Style.VEIL, 0.4))
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	_banner.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(Icons.rect("hourglass", 28, Style.VEIL))
	var word := Style.label("Coming soon", &"Strong")
	word.add_theme_color_override("font_color", Style.VEIL)
	row.add_child(word)
	_banner_text = Style.label("", &"Muted")
	_banner_text.add_theme_color_override("font_color", Style.TEXT_DIM)
	_banner_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_banner_text.custom_minimum_size.x = 600
	row.add_child(_banner_text)
	_banner.add_child(row)
	return _banner


func _build_results() -> Control:
	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.custom_minimum_size.y = 120
	body.clip_contents = true
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The cards' height follows their width: a bar that came and went with the height would make
	# the two chase each other, so its room is always kept.
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scrolled)
	body.add_child(_scroll)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_theme_constant_override("margin_right", 10)
	_scroll.add_child(inset)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 18)
	inset.add_child(list)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	list.add_child(_grid)
	_end = Style.label("", &"Muted")
	_end.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end.visible = false
	list.add_child(_end)
	var credit := Style.label("Models are made by the community and hosted by BeatMods. "
		+ "Kenbu downloads them for you alone and never passes them on.", &"Muted")
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(credit)
	var foot := Control.new()
	foot.custom_minimum_size.y = 8
	list.add_child(foot)

	_notice = VBoxContainer.new()
	_notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_notice.alignment = BoxContainer.ALIGNMENT_CENTER
	_notice.add_theme_constant_override("separation", 12)
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.visible = false
	_notice_icon = TextureRect.new()
	_notice_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_notice_icon.modulate = Style.TEXT_MUTED
	_notice.add_child(_notice_icon)
	_notice_title = Style.label("", &"Heading")
	_notice_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.add_child(_notice_title)
	_notice_text = Style.label("", &"Dim")
	_notice_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.add_child(_notice_text)
	_notice_button = Style.icon_button("refresh-cw", "Try again", &"GlassButton", 26)
	_notice_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_notice_button.custom_minimum_size.x = 260
	_notice_button.visible = false
	_notice_button.pressed.connect(_on_notice_pressed)
	_notice.add_child(_notice_button)
	body.add_child(_notice)
	return body


## Kenbu's theme plus this page's toggle look. A copy, so the shared theme is left as it is.
static func _theme() -> Theme:
	var t := Style.theme().duplicate() as Theme
	t.set_type_variation(&"ModelsToggle", &"Button")
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var on := state == "pressed" or state == "hover_pressed"
		var fill := Style.GLASS_HIGH if state == "hover" else Style.GLASS
		var style := Style.box(Color(Style.TIDE, 0.16) if on else fill, 18, 0.0,
			2 if on else 1, Color(Style.TIDE, 0.8) if on else Style.GLASS_EDGE)
		style.content_margin_left = 22
		style.content_margin_right = 22
		t.set_stylebox(state, &"ModelsToggle", style)
	t.set_stylebox("focus", &"ModelsToggle", t.get_stylebox("focus", &"GlassButton"))
	for item: String in ["font_color", "font_hover_color", "font_focus_color", "icon_normal_color",
			"icon_hover_color", "icon_focus_color"]:
		t.set_color(item, &"ModelsToggle", Style.TEXT_DIM)
	for item: String in ["font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(item, &"ModelsToggle", Style.TEXT)
	for item: String in ["icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(item, &"ModelsToggle", Style.TIDE)
	# A round button that sits on a preview picture.
	t.set_type_variation(&"ModelsRound", &"Button")
	var radius := int(Style.MIN_TARGET / 2.0)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var fill := Color(Style.BG, 0.82)
		if state == "hover":
			fill = Color(Style.HIGH, 0.95)
		elif state.contains("pressed"):
			fill = Color(Style.LINE, 0.95)
		t.set_stylebox(state, &"ModelsRound", Style.box(fill, radius, 0.0, 1, Style.GLASS_EDGE))
	var focus := Style.box(Color(0, 0, 0, 0), radius + 3, 0.0, 3, Color(Style.TIDE, 0.75))
	focus.draw_center = false
	focus.set_expand_margin_all(3)
	t.set_stylebox("focus", &"ModelsRound", focus)
	for item: String in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_focus_color", "icon_hover_pressed_color"]:
		t.set_color(item, &"ModelsRound", Style.TEXT)
	return t
