## Shaders translated from a model's compiled Unity programs (tools/kenbu-shader; docs/ARCHITECTURE.md,
## "Custom content"). kenbu-shader writes one Godot shader per Unity pass and a `shaders.json` index
## into the model's folder; this completes them per material and is what content/materials.gd uses
## for a shader no hand port covers.
##
## - `translate(bundle, dir)` runs the translator (blocking; content/loader.gd calls it on install).
## - `attach(entries, dir)` tags a model's sidecar materials with their translations, so
##   `build(entry, ...)` can make the material; `lookup(shader_name, hash)` finds a translation by
##   name and program hash for the hand-port tracks.
## - A translated material is a chain: one ShaderMaterial per Unity pass, linked by next_pass.
##   `set_parameter` sets a uniform on every pass.
##
## Per material, Unity's rules: the pass's blend, cull, depth write and depth test (fixed, or the
## float a `[_Prop]` names); colour properties linearised (source_color), floats and vectors raw;
## each sampler filtered, wrapped and sRGB-decoded as its texture says; `<tex>_ST`, `_TexelSize`
## and `_HDR` from the texture; textures the material leaves empty take the shader's default; a
## model's blended materials draw in the order of their render queues (`priority`, `_order`).
extends RefCounted

const Shaders = preload("res://content/shaders.gd")

const TRANSLATOR: String = "res://tools/bin/kenbu-shader"
const INDEX: String = "shaders.json"
const FORMAT: int = 1
const TIMEOUT_SECONDS: int = 120

## Unity's blend factors (Rendering.BlendMode).
const ZERO: int = 0
const ONE: int = 1
const DST_COLOR: int = 2
const SRC_COLOR: int = 3
const SRC_ALPHA: int = 5
const ONE_MINUS_SRC_COLOR: int = 6
const ONE_MINUS_SRC_ALPHA: int = 10
## ColorWriteMask's alpha bit.
const MASK_ALPHA: int = 1

## Folder -> its index, for every model whose materials were attached.
static var _indexes: Dictionary = {}
## Translation hash -> folder.
static var _by_hash: Dictionary = {}
## Shader file path -> its text.
static var _code: Dictionary = {}
static var _defaults: Dictionary = {}
static var _version: String = ""


static func translator_path() -> String:
	return ProjectSettings.globalize_path(TRANSLATOR)


## The translator's version line ("kenbu-shader 1.0.0"), or "" when it is not built.
static func translator_version() -> String:
	if _version.is_empty():
		var output: Array = []
		if FileAccess.file_exists(translator_path()) and OS.execute(translator_path(), ["--version"], output) == 0:
			_version = String(output[0]).strip_edges() if not output.is_empty() else ""
	return _version


## Translates the shaders of `bundle` into `dir` (blocking). Returns the translator's summary:
## {"ok": true, "shaders", "failed", "translations", "passes"} or {"ok": false, "error"}.
static func translate(bundle: String, dir: String, timeout_seconds: int = TIMEOUT_SECONDS) -> Dictionary:
	if not FileAccess.file_exists(translator_path()):
		return {"ok": false, "error": "kenbu-shader is not built (tools/kenbu-shader/build.sh)"}
	var output: Array = []
	var args := PackedStringArray([ProjectSettings.globalize_path(bundle), ProjectSettings.globalize_path(dir),
		"--timeout", str(timeout_seconds)])
	var code := OS.execute(translator_path(), args, output)
	var text := String(output[0]).strip_edges() if not output.is_empty() else ""
	var last := text.substr(text.rfind("\n") + 1)
	var parsed: Variant = JSON.parse_string(last)
	if parsed is Dictionary:
		return parsed
	return {"ok": false, "error": "kenbu-shader exited with %d: %s" % [code, last]}


## Whether `dir` holds translations this translator made.
static func is_current(dir: String) -> bool:
	var index := _read(dir.path_join(INDEX))
	return not index.is_empty() and String(index.get("translator", "")) == translator_version()


## The index kenbu-shader wrote into a model's folder ({} when there is none).
static func index(dir: String) -> Dictionary:
	if not _indexes.has(dir):
		var parsed := _read(dir.path_join(INDEX))
		if parsed.is_empty() or int(parsed.get("format", 0)) != FORMAT:
			return {}
		_indexes[dir] = parsed
		for hash: Variant in (parsed.get("translations", {}) as Dictionary):
			_by_hash[String(hash)] = dir
	return _indexes[dir]


## Tags each sidecar material `entries` holds (one model's) with its translation
## (`entry.translated`): {"dir", "hash", "states", "priority"}.
static func attach(entries: Array, dir: String) -> void:
	var materials: Dictionary = index(dir).get("materials", {})
	var tagged: Array[Dictionary] = []
	for e: Variant in entries:
		if not e is Dictionary:
			continue
		var entry: Dictionary = e
		var m: Variant = materials.get(String(entry.get("unity_id", "")))
		if m is Dictionary and (m as Dictionary).has("translation"):
			entry["translated"] = {"dir": dir, "hash": String(m.translation), "states": m.get("states", [])}
			tagged.append(entry)
	_order(tagged, dir)


## A Unity render queue's Godot render_priority, as content/materials.gd sets it (queue - 3000);
## below 2501, where Unity draws before every transparent queue, the lowest.
static func priority(queue: int) -> int:
	if queue < 2501:
		return Material.RENDER_PRIORITY_MIN
	return clampi(queue - 3000, Material.RENDER_PRIORITY_MIN, Material.RENDER_PRIORITY_MAX)


## The render priority of the first pass of each of a model's translated materials that Godot draws
## in its transparent pass (`translated.priority`; pass k adds k). Godot orders that pass by
## priority, then farthest first, where Unity orders by queue: queues the range would merge (a
## stencil mask at Geometry-1 and what it reveals at Geometry; Overlay and 5000) would draw by
## distance. Each queue keeps `priority(queue)`, moved only as far as the range forces, so the
## model's queues keep Unity's order.
static func _order(entries: Array[Dictionary], dir: String) -> void:
	var translations: Dictionary = index(dir).get("translations", {})
	var members: Array = []
	var slots: Dictionary = {}
	for entry in entries:
		var tag: Dictionary = entry.translated
		var t: Variant = translations.get(tag.hash)
		if not t is Dictionary:
			continue
		var passes: Array = t.get("passes", [])
		var states: Array = tag.get("states", [])
		var blended := false
		for k in passes.size():
			var state: Variant = states[k] if k < states.size() and states[k] is Dictionary else _resolve(passes[k].get("state", {}), entry)
			blended = blended or bool(header_for(state).blended)
		if not blended:
			continue
		var queue := _queue(entry, String(t.get("queue", "")))
		members.append([tag, queue])
		slots[queue] = maxi(int(slots.get(queue, 1)), passes.size())
	var queues: Array = slots.keys()
	queues.sort()
	var start: Dictionary = {}
	var next := Material.RENDER_PRIORITY_MIN
	for q: int in queues:
		start[q] = maxi(priority(q), next)
		next = int(start[q]) + int(slots[q])
	var limit := Material.RENDER_PRIORITY_MAX + 1
	for i in range(queues.size() - 1, -1, -1):
		var q: int = queues[i]
		start[q] = mini(int(start[q]), limit - int(slots[q]))
		limit = int(start[q])
	for member: Array in members:
		var tag: Dictionary = member[0]
		tag["priority"] = clampi(int(start[member[1]]), Material.RENDER_PRIORITY_MIN, Material.RENDER_PRIORITY_MAX)


## The translation of shader `shader_name` with program hash `hash` among the models attached so
## far: {"dir", "hash", "translation"}, or {}.
static func lookup(shader_name: String, hash: String) -> Dictionary:
	var dir: String = _by_hash.get(hash, "")
	if dir.is_empty():
		return {}
	var t: Variant = index(dir).get("translations", {}).get(hash)
	if not t is Dictionary or String(t.get("shader", "")) != shader_name:
		return {}
	return {"dir": dir, "hash": hash, "translation": t}


## The translation attached to a sidecar material, or {}.
static func for_entry(entry: Dictionary) -> Dictionary:
	var tag: Variant = entry.get("translated")
	if not tag is Dictionary:
		return {}
	var found := lookup(String(entry.get("shader", {}).get("name", "")), String(tag.hash))
	if found.is_empty():
		return {}
	found["states"] = tag.get("states", [])
	if tag.has("priority"):
		found["priority"] = tag.priority
	return found


## Builds the material for a sidecar material that has a translation: what content/materials.gd
## `build` returns, plus "translated": true, "uniforms" (Unity property -> shader parameter) and
## "unsupported" (features the translation leaves out). {} when there is no translation.
static func build(entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var found := for_entry(entry)
	if found.is_empty():
		return {}
	var t: Dictionary = found.translation
	var states: Array = found.get("states", [])
	var passes: Array = t.get("passes", [])
	var materials: Array[ShaderMaterial] = []
	var uniforms: Dictionary = {}
	var unsupported: PackedStringArray = []
	var transparent := false
	var queue := _queue(entry, String(t.get("queue", "")))
	var first := int(found.get("priority", priority(queue)))
	for k in passes.size():
		var p: Dictionary = passes[k]
		var state: Dictionary = states[k] if k < states.size() and states[k] is Dictionary else _resolve(p.get("state", {}), entry)
		var source := _source(String(found.dir).path_join(String(p.get("file", ""))))
		if source.is_empty():
			return {}
		var mat := ShaderMaterial.new()
		var samplers := _fill(mat, p.get("uniforms", []), entry, textures, texture_info)
		var header := header_for(state)
		transparent = transparent or bool(header.blended)
		mat.shader = Shaders.shader(complete(source, header, samplers))
		if queue >= 2501 or bool(header.blended):
			mat.render_priority = clampi(first + k, Material.RENDER_PRIORITY_MIN, Material.RENDER_PRIORITY_MAX)
		for u: Variant in p.get("uniforms", []):
			if String(u.get("role", "")) == "property":
				uniforms[String(u.unity)] = StringName(String(u.name))
		for f: Variant in p.get("unsupported", []):
			if not unsupported.has(String(f)):
				unsupported.append(String(f))
		materials.append(mat)
	for k in range(materials.size() - 1):
		materials[k].next_pass = materials[k + 1]
	if materials.is_empty():
		return {}
	return {
		"material": materials[0],
		"shader": String(t.get("shader", "")),
		"family": Shaders.Family.FALLBACK,
		"approximate": not unsupported.is_empty(),
		"queue": queue,
		"transparent": transparent,
		"translated": true,
		"uniforms": uniforms,
		"unsupported": unsupported,
	}


## Sets a uniform on every pass of a (translated) material chain.
static func set_parameter(material: Material, param: StringName, value: Variant) -> void:
	var m := material
	while m != null:
		if m is ShaderMaterial:
			(m as ShaderMaterial).set_shader_parameter(param, value)
		m = m.next_pass


## Godot render modes, the KENBU_ defines and the stencil line of a pass's resolved Unity state:
## {"modes": PackedStringArray, "defines": PackedStringArray, "blended": bool, "stencil": String}.
static func header_for(state: Dictionary) -> Dictionary:
	var blend: Array = state.get("blend", [ONE, ZERO])
	var src := int(_n(blend[0] if blend.size() > 0 else ONE))
	var dst := int(_n(blend[1] if blend.size() > 1 else ZERO))
	var blend_alpha: Array = state.get("blend_alpha", blend)
	var src_alpha := int(_n(blend_alpha[0] if blend_alpha.size() > 0 else src))
	var mask := int(_n(state.get("color_mask", 15)))
	var zwrite := int(_n(state.get("zwrite", 1))) != 0
	var ztest := int(_n(state.get("ztest", 4)))
	var cull := int(_n(state.get("cull", 2)))
	var modes: PackedStringArray = ["unshaded", "fog_disabled"]
	var defines: PackedStringArray = []
	var blended := true
	var alpha := "clamp((c).a, 0.0, 1.0)"
	var glow := true
	if mask == 0 or (src == ZERO and dst == ONE):
		# Depth only (ColorMask 0, or Blend Zero One): drawn fully transparent.
		modes.append("blend_mix")
		alpha = "0.0"
		glow = false
	elif src == ONE and dst == ZERO:
		modes.append("blend_mix")
		blended = false
	elif dst == ONE:
		modes.append("blend_add")
		# Godot's add scales by ALPHA; Unity's One One (and screen, OneMinusDstColor One) does not.
		if src != SRC_ALPHA:
			alpha = "1.0"
	elif src == ONE and dst == ONE_MINUS_SRC_ALPHA:
		modes.append("blend_premul_alpha")
	elif src == ONE and dst == ONE_MINUS_SRC_COLOR:
		# Soft additive, src + dst x (1 - src): premultiplied blending by the colour's peak.
		modes.append("blend_premul_alpha")
		alpha = "clamp(max(max((c).r, (c).g), (c).b), 0.0, 1.0)"
	elif src == DST_COLOR or dst == SRC_COLOR:
		modes.append("blend_mul")
		alpha = "1.0"
		glow = false
	else:
		modes.append("blend_mix")
	# Godot draws a material that reads the stencil only in its transparent pass: an opaque Unity
	# pass that does is drawn there fully opaque, writing depth as before.
	var stencil := stencil_for(state.get("stencil", {}))
	if not blended and stencil.contains(" read"):
		blended = true
		alpha = "1.0"
		zwrite = true
	match cull:
		0:
			modes.append("cull_disabled")
		1:
			modes.append("cull_front")
		_:
			modes.append("cull_back")
	if blended and zwrite:
		modes.append("depth_draw_always")
	elif not blended and not zwrite:
		modes.append("depth_draw_never")
	else:
		modes.append("depth_draw_opaque")
	# Unity's ZTest Always (8), or disabled (0); Greater (5) and GEqual (7) draw only behind what is
	# there. Equal and NotEqual have no Godot form and test as LEqual.
	if ztest == 8 or ztest == 0:
		modes.append("depth_test_disabled")
	elif ztest == 5 or ztest == 7:
		modes.append("depth_test_inverted")
	if not blended:
		defines.append("#define KENBU_OPAQUE")
	# Beat Saber's bloom reads the alpha that reaches the target: none without the alpha channel,
	# squared when blending scales it by itself.
	if not glow or mask & MASK_ALPHA == 0:
		defines.append("#define KENBU_NO_GLOW")
	elif blended and src_alpha == SRC_ALPHA:
		defines.append("#define KENBU_GLOW(c) ((c).a * (c).a)")
	elif blended and src_alpha == ZERO:
		defines.append("#define KENBU_NO_GLOW")
	if not defines.has("#define KENBU_NO_GLOW") and not defines.has("#define KENBU_GLOW(c) ((c).a * (c).a)"):
		defines.append("#define KENBU_GLOW(c) (c).a")
	defines.append("#define KENBU_ALPHA(c) " + alpha)
	return {"modes": modes, "defines": defines, "blended": blended, "stencil": stencil}


## Godot's stencil_mode line for a Unity stencil state ("" when the pass does not use the stencil).
## Unity tests `ref <comp> buffer` (CompareFunction: 1 Never ... 8 Always) and on a pass, or on a
## depth failure, may write the reference (StencilOp 2 Replace); Godot's modes are those: read with a
## comparison, write, write_depth_fail. Masks and the other operations have no Godot form.
static func stencil_for(stencil: Variant) -> String:
	if not stencil is Dictionary:
		return ""
	var s: Dictionary = stencil
	var ops: Dictionary = s.get("front", {}) if s.get("front") is Dictionary else {}
	var plain: Dictionary = s.get("op", {}) if s.get("op") is Dictionary else {}
	if int(_n(ops.get("comp", 8))) == 8 and int(_n(ops.get("pass", 0))) == 0 and int(_n(ops.get("zfail", 0))) == 0:
		ops = plain
	var comp := int(_n(ops.get("comp", 8)))
	var pass_op := int(_n(ops.get("pass", 0)))
	var zfail := int(_n(ops.get("zfail", 0)))
	const COMPARE: Dictionary = {2: "compare_less", 3: "compare_equal", 4: "compare_less_or_equal",
		5: "compare_greater", 6: "compare_not_equal", 7: "compare_greater_or_equal", 8: "compare_always"}
	var reads := comp != 8 and COMPARE.has(comp)
	# StencilOp Zero (1) clears. Godot writes its one reference, so a clear is the reference 0 when
	# the test needs none; behind a test it is left out rather than written as the reference. It then
	# changes nothing where the passing buffer already holds 0, as under the BeatMods "Overlay"
	# shaders (Ref 2 Comp Greater Pass Zero over 0, or a "Priority" partner's 2, which fails).
	var writes := pass_op != 0 and not (pass_op == 1 and reads)
	var writes_depth_fail := zfail != 0 and not (zfail == 1 and reads)
	var parts: PackedStringArray = []
	if reads:
		parts.append("read")
	if writes:
		parts.append("write")
	elif writes_depth_fail:
		parts.append("write_depth_fail")
	if parts.is_empty():
		return ""
	var reference := clampi(int(_n(s.get("ref", 0))), 0, 255)
	if (pass_op == 1 or zfail == 1) and not reads:
		reference = 0
	parts.append(String(COMPARE.get(comp, "compare_always")))
	parts.append(str(reference))
	return "stencil_mode %s;" % ", ".join(parts)


## A translated pass's code with this material's header lines: the render modes, the KENBU_
## defines, the glow constants and each sampler's hints (`samplers`: uniform name -> hint list).
static func complete(source: String, header: Dictionary, samplers: Dictionary) -> String:
	var out := PackedStringArray()
	var defines_done := false
	for line in source.split("\n"):
		if line.begins_with("render_mode "):
			out.append("render_mode %s;" % ", ".join(header.modes))
			if not String(header.get("stencil", "")).is_empty():
				out.append(String(header.stencil))
		elif line.begins_with("#define KENBU_"):
			if not defines_done:
				out.append_array(header.defines)
				defines_done = true
		elif line.begins_with("const float GLOW_ENERGY"):
			out.append("const float GLOW_ENERGY = %s;" % str(Shaders.GLOW_ENERGY))
		elif line.begins_with("const float GLOW_WHITEN"):
			out.append("const float GLOW_WHITEN = %s;" % str(Shaders.GLOW_WHITEN))
		elif line.begins_with("uniform sampler") and not line.contains("hint_screen_texture") and not line.contains("hint_depth_texture"):
			var words := line.split(" ", false)
			var uname := words[2] if words.size() > 2 else ""
			if samplers.has(uname):
				out.append("uniform %s %s : %s;" % [words[1], uname, samplers[uname]])
			else:
				out.append(line)
		else:
			out.append(line)
	return "\n".join(out)


## Sets the pass's uniforms from the material; returns the sampler hints per sampler uniform.
static func _fill(mat: ShaderMaterial, uniforms: Array, entry: Dictionary, textures: Array, texture_info: Array) -> Dictionary:
	var samplers: Dictionary = {}
	var declared := _declared(entry)
	var slots: Dictionary = entry.get("textures", {}) if entry.get("textures") is Dictionary else {}
	for u: Variant in uniforms:
		var uname := StringName(String(u.get("name", "")))
		var unity := String(u.get("unity", ""))
		var ty := String(u.get("type", ""))
		match String(u.get("role", "")):
			"property":
				var value: Variant = _property(entry, declared, unity, ty)
				if value != null:
					mat.set_shader_parameter(uname, value)
			"scale_offset":
				var slot: Dictionary = slots.get(String(u.get("texture", "")), {})
				var s: Array = slot.get("scale", [1.0, 1.0])
				var o: Array = slot.get("offset", [0.0, 0.0])
				mat.set_shader_parameter(uname, _shaped(Vector4(_n(s[0]), _n(s[1]), _n(o[0]), _n(o[1])), ty))
			"texel_size":
				var info := _info(slots.get(String(u.get("texture", "")), {}), texture_info)
				var w := maxf(_n(info.get("width", 1)), 1.0)
				var h := maxf(_n(info.get("height", 1)), 1.0)
				mat.set_shader_parameter(uname, _shaped(Vector4(1.0 / w, 1.0 / h, w, h), ty))
			"texture", "global":
				if not ty.begins_with("sampler"):
					continue
				var slot: Dictionary = slots.get(unity, {})
				var tex := _texture(slot, textures)
				var info := _info(slot, texture_info)
				# A Unity global nothing sets (a reflection probe, a light cookie) reads black.
				var default := String(declared.get(unity, {}).get("texture_default", "white")) if declared.has(unity) else "black"
				if tex == null:
					tex = _default_texture(default, ty)
				if tex != null:
					mat.set_shader_parameter(uname, tex)
				samplers[String(uname)] = _hints(info, ty, default)
	return samplers


## Shader properties as the sidecar declares them, by name.
static func _declared(entry: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var shader: Dictionary = entry.get("shader", {}) if entry.get("shader") is Dictionary else {}
	for p: Variant in shader.get("properties", []):
		if p is Dictionary:
			out[String(p.get("name", ""))] = p
	return out


## A property's value as Unity uploads it: the material's saved value, else the shader's default.
static func _property(entry: Dictionary, declared: Dictionary, unity: String, ty: String) -> Variant:
	var floats: Dictionary = entry.get("floats", {}) if entry.get("floats") is Dictionary else {}
	var ints: Dictionary = entry.get("ints", {}) if entry.get("ints") is Dictionary else {}
	var colors: Dictionary = entry.get("colors", {}) if entry.get("colors") is Dictionary else {}
	var dflt: Array = declared.get(unity, {}).get("default", [0.0, 0.0, 0.0, 0.0])
	var d := Vector4(_n(dflt[0]), _n(dflt[1]), _n(dflt[2]), _n(dflt[3])) if dflt.size() >= 4 else Vector4.ZERO
	var kind := int(declared.get(unity, {}).get("type", 2))
	match ty:
		"float", "int", "uint", "bool":
			var f: float = d.x
			if floats.has(unity):
				f = _n(floats[unity])
			elif ints.has(unity):
				f = _n(ints[unity])
			match ty:
				"int":
					return int(f)
				"uint":
					return maxi(int(f), 0)
				"bool":
					return f != 0.0
			return f
		"vec2", "vec3", "vec4":
			var v := d
			var c: Variant = colors.get(unity)
			if c is Array and (c as Array).size() >= 4:
				v = Vector4(_n(c[0]), _n(c[1]), _n(c[2]), _n(c[3]))
			# Colour properties are declared source_color: Godot linearises the Color, as Unity does.
			if kind == 0 and ty != "vec2":
				return Color(v.x, v.y, v.z, v.w)
			return _shaped(v, ty)
	return null


static func _shaped(v: Vector4, ty: String) -> Variant:
	match ty:
		"float":
			return v.x
		"vec2":
			return Vector2(v.x, v.y)
		"vec3":
			return Vector3(v.x, v.y, v.z)
	return v


static func _texture(slot: Dictionary, textures: Array) -> Texture:
	var index: Variant = slot.get("texture")
	if index == null or int(index) < 0 or int(index) >= textures.size():
		return null
	return textures[int(index)] as Texture


static func _info(slot: Dictionary, texture_info: Array) -> Dictionary:
	var index: Variant = slot.get("texture")
	if index == null or int(index) < 0 or int(index) >= texture_info.size():
		return {}
	return texture_info[int(index)]


## Sampler hints from a texture's import settings (Unity's filter 0 point, 1 bilinear, 2 trilinear;
## wrap 0 repeat, 1 clamp; sRGB by its colour space).
static func _hints(info: Dictionary, ty: String, default: String) -> String:
	var hints: PackedStringArray = []
	var srgb := bool(info.get("srgb", default != "bump")) if not info.is_empty() else default not in ["bump", "linearGray"]
	if srgb and ty != "sampler3D":
		hints.append("source_color")
	hints.append("hint_default_black" if default == "black" else "hint_default_white")
	var mips := int(info.get("mips", 2)) > 1
	if int(info.get("filter", 1)) == 0:
		hints.append("filter_nearest_mipmap" if mips else "filter_nearest")
	elif mips and int(info.get("aniso", 1)) > 1:
		hints.append("filter_linear_mipmap_anisotropic")
	else:
		hints.append("filter_linear_mipmap" if mips else "filter_linear")
	var wrap: Array = info.get("wrap", [0, 0])
	var clamped := not wrap.is_empty() and int(wrap[0]) == 1 and int(wrap[-1]) == 1
	if ty == "sampler2D" or ty == "sampler2DArray" or ty == "sampler3D":
		hints.append("repeat_disable" if clamped else "repeat_enable")
	return ", ".join(hints)


## Unity's default textures by name ("white", "black", "gray", "bump", "red"), as one-texel images.
static func _default_texture(default: String, ty: String) -> Texture:
	if ty != "sampler2D":
		return null
	var color: Color
	match default:
		"black":
			color = Color(0.0, 0.0, 0.0, 0.0)
		"gray", "grey":
			color = Color(0.5, 0.5, 0.5, 0.5)
		"bump":
			color = Color(0.5, 0.5, 1.0, 0.5)
		"red":
			color = Color(1.0, 0.0, 0.0, 0.0)
		_:
			return null
	var ref: WeakRef = _defaults.get(default)
	var tex: ImageTexture = ref.get_ref() as ImageTexture if ref != null else null
	if tex == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(color)
		tex = ImageTexture.create_from_image(image)
		_defaults[default] = weakref(tex)
	return tex


## A Unity state with each `[_Prop]` name replaced by the material's float (or the shader's default).
static func _resolve(state: Variant, entry: Dictionary) -> Variant:
	if state is String:
		var floats: Dictionary = entry.get("floats", {}) if entry.get("floats") is Dictionary else {}
		if floats.has(state):
			return _n(floats[state])
		var d: Array = _declared(entry).get(String(state), {}).get("default", [0.0])
		return _n(d[0]) if not d.is_empty() else 0.0
	if state is Array:
		var out: Array = []
		for v: Variant in state:
			out.append(_resolve(v, entry))
		return out
	if state is Dictionary:
		var out: Dictionary = {}
		for k: Variant in state:
			out[k] = _resolve(state[k], entry)
		return out
	return state


## The material's render queue: its own, else its shader's Queue tag ("Transparent+1").
static func _queue(entry: Dictionary, tag: String) -> int:
	var own: Variant = entry.get("render_queue")
	if own != null and int(own) >= 0:
		return int(own)
	var t := tag.strip_edges().to_lower()
	const QUEUES: Dictionary = {"background": 1000, "geometry": 2000, "alphatest": 2450, "geometrylast": 2500,
		"transparent": 3000, "overlay": 4000}
	if t.is_empty():
		return 2000
	if t.is_valid_int():
		return t.to_int()
	var cut := t.find("+")
	var sign := 1
	if cut < 0:
		cut = t.find("-")
		sign = -1
	var base := t if cut < 0 else t.substr(0, cut)
	return int(QUEUES.get(base, 2000)) + (0 if cut < 0 else t.substr(cut + 1).to_int() * sign)


static func _n(v: Variant) -> float:
	return float(v) if v is float or v is int else 0.0


static func _source(path: String) -> String:
	if not _code.has(path):
		if not FileAccess.file_exists(path):
			return ""
		_code[path] = FileAccess.get_file_as_string(path)
	return _code[path]


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
