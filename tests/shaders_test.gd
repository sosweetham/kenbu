## Translated shaders (tools/kenbu-shader, content/translated/): Unity render state becomes Godot's,
## a translation completes per material (header lines, sampler hints, Unity property values,
## default textures, passes chained), the lookup by shader name and program hash, and every
## completed shader compiling in Godot's shader compiler (a headless run compiles; errors are
## caught through a Logger).
##
## With the translator built (tools/kenbu-shader/build.sh) and the BeatMods mirror present
## (MODELSABER_DIR, default ~/projs/modelsaber; skipped when missing), a fixed set of real models
## covering the cases (an SDK shader, community trails, a GrabPass, tessellation, multi-pass, a
## matcap, platforms and avatars) is imported, translated and loaded through content/loader.gd:
## every material with a translation must build from it, every shader must compile, and materials
## without a hand port must come out translated, not guessed.
## Run: godot --headless --xr-mode off --path . --script res://tests/shaders_test.gd
extends SceneTree

const Loader = preload("res://content/loader.gd")
const Materials = preload("res://content/materials.gd")
const Translated = preload("res://content/translated/translated.gd")

## BeatMods ids: Unlit Glow and Particles/Additive (3947), Lit Glow and Fire Trail (4093), Uber with
## its GrabPass (5415), Cosmic Fresnel and Mdot/Plasma (5433), tessellated DistortionFlow (6478),
## BeatSaber P/Complete notes (4159), a platform (4961), an avatar (4120), sabers built with Unity
## 2021.3 (7976) and 6000.0 (7927), whose bindings sit in parameter records, and a .whacker (7977).
const FIXED: PackedStringArray = ["3947", "4093", "5415", "5433", "6478", "4159", "4961", "4120", "7976", "7927",
	"7977"]
const EXTENSIONS: PackedStringArray = ["saber", "whacker", "bloq", "plat", "avatar"]
const FAILURES_SHOWN: int = 12

## A pass as kenbu-shader writes it (the header lines the material completes come first).
const TEMPLATE: String = """shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, cull_back, depth_draw_opaque;
#define KENBU_OPAQUE
#define KENBU_GLOW(c) (c).a

const float GLOW_ENERGY = 2.0;
const float GLOW_WHITEN = 0.8;

uniform vec4 _MainTex_ST = vec4(1.0, 1.0, 0.0, 0.0);
uniform sampler2D _MainTex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D _BumpMap : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 _Color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float _Glow = 0.0;
uniform vec4 _MainTex_TexelSize = vec4(1.0);

varying vec4 vs_TEXCOORD0;

vec3 kenbu_glowing(vec3 rgb, float g) {
	float k = clamp(g, 0.0, 1.0);
	float peak = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, vec3(peak), GLOW_WHITEN * k) + rgb * (GLOW_ENERGY * k);
}

void vertex() {
	vs_TEXCOORD0 = vec4(UV * _MainTex_ST.xy + _MainTex_ST.zw, 0.0, 1.0);
}

void fragment() {
	vec4 o0 = texture(_MainTex, vs_TEXCOORD0.xy) * _Color * vec4(texture(_BumpMap, vs_TEXCOORD0.xy).a);
	o0.w = o0.w * _Glow + _MainTex_TexelSize.x * 0.0;
#ifdef KENBU_NO_GLOW
	ALBEDO = o0.rgb;
#else
	ALBEDO = kenbu_glowing(o0.rgb, KENBU_GLOW(o0));
#endif
#ifndef KENBU_OPAQUE
	ALPHA = KENBU_ALPHA(o0);
#endif
}
"""


## Godot's shader errors while a shader compiles.
class Catch extends Logger:
	var errors: PackedStringArray = []
	var mutex := Mutex.new()

	func _log_error(_function: String, _file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_SHADER or rationale.contains("hader compilation"):
			mutex.lock()
			errors.append("%s (line %d)" % [code if not code.is_empty() else rationale, line])
			mutex.unlock()

	func take() -> PackedStringArray:
		mutex.lock()
		var out := errors
		errors = []
		mutex.unlock()
		return out


var _failures: int = 0
var _checks: int = 0
var _shown: int = 0
var _started: bool = false
var _catch := Catch.new()
var _work: String = ""


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run.call_deferred()
	return false


func _run() -> void:
	OS.add_logger(_catch)
	_work = "user://shaders_test-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(_work)
	_check_headers()
	_check_complete()
	_check_synthetic()
	_check_order()
	_check_models()
	Loader.remove_tree(_work)
	print("shaders_test: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		_shown += 1
		if _shown <= FAILURES_SHOWN:
			print("FAIL ", message)


func _state(src: int, dst: int, extra: Dictionary = {}) -> Dictionary:
	var s := {"blend": [src, dst], "blend_alpha": [src, dst], "color_mask": 15, "zwrite": 1, "ztest": 4, "cull": 2}
	s.merge(extra, true)
	return s


## Unity's blend factors, culling, depth write and test as Godot render modes and KENBU_ defines.
func _check_headers() -> void:
	var opaque := Translated.header_for(_state(1, 0))
	_expect(Array(opaque.modes) == ["unshaded", "fog_disabled", "blend_mix", "cull_back", "depth_draw_opaque"], "opaque modes: %s" % [opaque.modes])
	_expect(opaque.defines.has("#define KENBU_OPAQUE") and opaque.defines.has("#define KENBU_GLOW(c) (c).a"), "opaque glows by alpha: %s" % [opaque.defines])
	_expect(not opaque.blended, "One Zero is opaque")
	var additive := Translated.header_for(_state(5, 1, {"zwrite": 0, "cull": 0}))
	_expect(additive.modes.has("blend_add") and additive.modes.has("cull_disabled"), "SrcAlpha One adds, Cull Off: %s" % [additive.modes])
	_expect(additive.defines.has("#define KENBU_GLOW(c) ((c).a * (c).a)"), "alpha blended into alpha glows by its square: %s" % [additive.defines])
	_expect(additive.defines.has("#define KENBU_ALPHA(c) clamp((c).a, 0.0, 1.0)"), "SrcAlpha One keeps alpha")
	var one_one := Translated.header_for(_state(1, 1, {"zwrite": 0}))
	_expect(one_one.modes.has("blend_add") and one_one.defines.has("#define KENBU_ALPHA(c) 1.0"), "One One adds unscaled: %s" % [one_one.defines])
	var premul := Translated.header_for(_state(1, 10, {"zwrite": 0}))
	_expect(premul.modes.has("blend_premul_alpha"), "One OneMinusSrcAlpha is premultiplied: %s" % [premul.modes])
	var mul := Translated.header_for(_state(2, 0, {"zwrite": 0}))
	_expect(mul.modes.has("blend_mul") and mul.defines.has("#define KENBU_NO_GLOW"), "DstColor Zero multiplies, no glow")
	var mix := Translated.header_for(_state(5, 10, {"zwrite": 1, "ztest": 8, "cull": 1}))
	_expect(mix.modes.has("blend_mix") and mix.modes.has("depth_draw_always") and mix.modes.has("depth_test_disabled") and mix.modes.has("cull_front"),
		"alpha blend writing depth, ZTest Always, Cull Front: %s" % [mix.modes])
	var behind := Translated.header_for(_state(1, 0, {"ztest": 5}))
	_expect(behind.modes.has("depth_test_inverted"), "ZTest Greater draws behind: %s" % [behind.modes])
	var rgb := Translated.header_for(_state(1, 0, {"color_mask": 14}))
	_expect(rgb.defines.has("#define KENBU_NO_GLOW"), "ColorMask RGB writes no alpha, so no glow")
	var depth_only := Translated.header_for(_state(1, 0, {"color_mask": 0}))
	_expect(depth_only.blended and depth_only.defines.has("#define KENBU_ALPHA(c) 0.0") and depth_only.modes.has("depth_draw_always"),
		"ColorMask 0 draws depth only: %s %s" % [depth_only.modes, depth_only.defines])
	var mask_only := Translated.header_for(_state(1, 0, {"color_mask": 0, "zwrite": 0}))
	_expect(mask_only.modes.has("depth_draw_opaque") and not mask_only.modes.has("depth_draw_always"),
		"ColorMask 0 with ZWrite Off (a stencil mask) writes no depth: %s" % [mask_only.modes])
	var nothing := Translated.header_for(_state(0, 1, {"zwrite": 0}))
	_expect(nothing.defines.has("#define KENBU_ALPHA(c) 0.0"), "Blend Zero One draws nothing: %s" % [nothing.defines])
	var soft := Translated.header_for(_state(1, 6, {"zwrite": 0}))
	_expect(soft.modes.has("blend_premul_alpha") and String(soft.defines[-1]).contains("max(max((c).r"), "One OneMinusSrcColor blends by the colour's peak")
	var no_write := Translated.header_for(_state(1, 0, {"zwrite": 0}))
	_expect(no_write.modes.has("depth_draw_never"), "opaque ZWrite Off: %s" % [no_write.modes])
	var keep := {"pass": 0, "fail": 0, "zfail": 0, "comp": 8}
	_expect(String(opaque.stencil).is_empty(), "no stencil by default")
	var writer := Translated.header_for(_state(1, 0, {"stencil": {"ref": 2, "op": keep, "front": {"pass": 2, "fail": 0, "zfail": 0, "comp": 8}}}))
	_expect(writer.stencil == "stencil_mode write, compare_always, 2;", "Stencil Ref 2 Pass Replace writes: %s" % writer.stencil)
	var clearer := Translated.header_for(_state(1, 0, {"stencil": {"ref": 5, "op": keep, "front": {"pass": 1, "fail": 0, "zfail": 0, "comp": 8}}}))
	_expect(clearer.stencil == "stencil_mode write, compare_always, 0;", "Stencil Pass Zero clears: %s" % clearer.stencil)
	var overlay := Translated.header_for(_state(1, 0, {"stencil": {"ref": 2, "op": {"pass": 1, "fail": 0, "zfail": 0, "comp": 5}, "front": keep}}))
	_expect(overlay.stencil == "stencil_mode read, compare_greater, 2;",
		"Comp Greater Pass Zero reads and never writes its reference: %s" % overlay.stencil)
	var reader := Translated.header_for(_state(1, 0, {"stencil": {"ref": 1, "op": {"pass": 0, "fail": 0, "zfail": 0, "comp": 6}, "front": keep}}))
	_expect(reader.stencil == "stencil_mode read, compare_not_equal, 1;", "Stencil Ref 1 Comp NotEqual reads: %s" % reader.stencil)
	_expect(reader.blended and reader.modes.has("depth_draw_always") and reader.defines.has("#define KENBU_ALPHA(c) 1.0"),
		"an opaque stencil reader draws in Godot's transparent pass, opaque: %s %s" % [reader.modes, reader.defines])
	var masked := Translated.complete(TEMPLATE, reader, {})
	_expect(masked.contains("stencil_mode read, compare_not_equal, 1;") and _compiles(masked).is_empty(), "a stencil pass compiles")
	var inverted := Translated.complete(TEMPLATE, behind, {})
	_expect(inverted.contains("depth_test_inverted") and _compiles(inverted).is_empty(), "an inverted depth test compiles")


## The header lines a material rewrites, and nothing else.
func _check_complete() -> void:
	var header := Translated.header_for(_state(5, 1, {"zwrite": 0, "cull": 0}))
	var code := Translated.complete(TEMPLATE, header, {"_MainTex": "source_color, hint_default_white, filter_nearest, repeat_disable"})
	_expect(code.contains("render_mode unshaded, fog_disabled, blend_add, cull_disabled, depth_draw_opaque;"), "render_mode rewritten")
	_expect(not code.contains("#define KENBU_OPAQUE") and code.contains("#define KENBU_GLOW(c) ((c).a * (c).a)"), "defines rewritten")
	_expect(code.contains("uniform sampler2D _MainTex : source_color, hint_default_white, filter_nearest, repeat_disable;"), "sampler hints rewritten")
	_expect(code.contains("uniform sampler2D _BumpMap : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;"), "unlisted samplers kept")
	_expect(code.contains("const float GLOW_ENERGY = %s;" % str(Translated.Shaders.GLOW_ENERGY)), "glow constants follow content/shaders.gd")
	_expect(code.split("\n").size() == TEMPLATE.split("\n").size() + header.defines.size() - 2, "only header lines change")
	_expect(_compiles(code).is_empty(), "the completed template compiles: %s" % [_compiles(code)])


## A translation as kenbu-shader writes it, built for a sidecar material: values, textures,
## sampler hints, queue, the pass chain and the lookup.
func _check_synthetic() -> void:
	var dir := _work.path_join("synthetic")
	DirAccess.make_dir_recursive_absolute(dir.path_join("shaders"))
	var file := FileAccess.open(dir.path_join("shaders/aa_0.gdshader"), FileAccess.WRITE)
	file.store_string(TEMPLATE)
	file.close()
	var uniforms := [
		{"name": "_MainTex_ST", "unity": "_MainTex_ST", "type": "vec4", "array": 0, "role": "scale_offset", "texture": "_MainTex"},
		{"name": "_MainTex", "unity": "_MainTex", "type": "sampler2D", "array": 0, "role": "texture", "texture": ""},
		{"name": "_BumpMap", "unity": "_BumpMap", "type": "sampler2D", "array": 0, "role": "texture", "texture": ""},
		{"name": "_Color", "unity": "_Color", "type": "vec4", "array": 0, "role": "property", "texture": ""},
		{"name": "_Glow", "unity": "_Glow", "type": "float", "array": 0, "role": "property", "texture": ""},
		{"name": "_MainTex_TexelSize", "unity": "_MainTex_TexelSize", "type": "vec4", "array": 0, "role": "texel_size", "texture": "_MainTex"},
	]
	var pass_entry := {"file": "shaders/aa_0.gdshader", "light_mode": "", "state": _state(1, 0), "uniforms": uniforms, "unsupported": []}
	var additive_pass := pass_entry.duplicate(true)
	additive_pass.state = _state(5, 1, {"zwrite": 0})
	var index := {
		"format": Translated.FORMAT,
		"translator": "kenbu-shader test",
		"materials": {"11": {"name": "m", "shader": "Test/Two", "shader_id": "5", "translation": "aa",
			"states": [_state(1, 0), _state(5, 1, {"zwrite": 0})]}},
		"translations": {"aa": {"shader": "Test/Two", "keywords": [], "queue": "Transparent", "warnings": [],
			"passes": [pass_entry, additive_pass]}},
		"shaders": {"5": {"name": "Test/Two", "translations": ["aa"]}},
	}
	var out := FileAccess.open(dir.path_join("shaders.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(index))
	out.close()
	var image := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	var texture := ImageTexture.create_from_image(image)
	var entry := {
		"name": "m", "unity_id": "11", "render_queue": -1,
		"shader": {"name": "Test/Two", "unity_id": "5", "properties": [
			{"name": "_Color", "type": 0, "default": [1, 1, 1, 1]},
			{"name": "_Glow", "type": 3, "default": [0.25, 0, 1, 0]},
			{"name": "_MainTex", "type": 4, "texture_default": "white"},
			{"name": "_BumpMap", "type": 4, "texture_default": "bump"}]},
		"floats": {}, "colors": {"_Color": [0.5, 0.25, 1.0, 1.0]},
		"textures": {"_MainTex": {"scale": [2.0, 3.0], "offset": [0.5, 0.0], "texture": 0}},
	}
	var info := [{"width": 4, "height": 2, "srgb": true, "filter": 0, "wrap": [1, 1], "mips": 1}]
	Translated.attach([entry], dir)
	_expect(entry.has("translated"), "attach tags the material with its translation")
	_expect(not Translated.lookup("Test/Two", "aa").is_empty(), "lookup by shader name and program hash")
	_expect(Translated.lookup("Other/Name", "aa").is_empty(), "lookup refuses another shader's hash")
	var built := Translated.build(entry, [texture], info)
	_expect(not built.is_empty() and bool(built.get("translated", false)), "a translated material builds")
	if built.is_empty():
		return
	var first: ShaderMaterial = built.material
	var second := first.next_pass as ShaderMaterial
	_expect(second != null and second.next_pass == null, "two passes chain through next_pass")
	_expect(first.get_shader_parameter(&"_Color") == Color(0.5, 0.25, 1.0, 1.0), "a colour property as stored (Godot linearises it)")
	_expect(is_equal_approx(float(first.get_shader_parameter(&"_Glow")), 0.25), "an unsaved float takes the shader's default")
	_expect(first.get_shader_parameter(&"_MainTex_ST") == Vector4(2.0, 3.0, 0.5, 0.0), "_ST from the slot's scale and offset")
	_expect(first.get_shader_parameter(&"_MainTex_TexelSize") == Vector4(0.25, 0.5, 4.0, 2.0), "_TexelSize from the texture")
	_expect(first.get_shader_parameter(&"_MainTex") == texture, "the slot's texture")
	var bump: Texture2D = first.get_shader_parameter(&"_BumpMap")
	var texel := bump.get_image().get_pixel(0, 0) if bump != null else Color.BLACK
	_expect(absf(texel.r - 0.5) < 0.01 and absf(texel.b - 1.0) < 0.01 and absf(texel.a - 0.5) < 0.01, "an empty slot takes Unity's default (bump): %s" % texel)
	_expect(first.shader.code.contains("uniform sampler2D _MainTex : source_color, hint_default_white, filter_nearest, repeat_disable;"),
		"sampler hints from the texture (point, clamped, no mips)")
	_expect(first.shader.code.contains("uniform sampler2D _BumpMap : hint_default_white,"), "a bump default is linear")
	_expect(second.shader.code.contains("blend_add") and not first.shader.code.contains("blend_add"), "each pass has its own state")
	_expect(int(built.queue) == 3000 and second.render_priority == 1, "queue from the shader's tag; passes in order")
	_expect(bool(built.transparent), "a blended pass makes the material transparent")
	_expect(StringName(built.uniforms.get("_Color", &"")) == &"_Color", "the colour uniform is reported for mods")
	Translated.set_parameter(first, &"_Color", Color.RED)
	_expect(second.get_shader_parameter(&"_Color") == Color.RED, "set_parameter reaches every pass")
	for m: ShaderMaterial in [first, second]:
		_expect(_compiles(m.shader.code).is_empty(), "a built pass compiles: %s" % [_compiles(m.shader.code)])
	# Materials without a hand port come out translated.
	entry.shader = (entry.shader as Dictionary).duplicate()
	var through := Materials.build(entry, [texture], info)
	_expect(bool(through.get("translated", false)), "content/materials.gd uses the translation for an unported shader")


## Godot's transparent pass draws by render_priority, then farthest first; Unity by render queue.
## A model's blended translated materials keep Unity's queue order, also where queue - 3000 leaves
## the range (a stencil mask at 2501 drawn before what it reveals at 2510; Overlay and 5000).
func _check_order() -> void:
	var dir := _work.path_join("order")
	DirAccess.make_dir_recursive_absolute(dir.path_join("shaders"))
	var file := FileAccess.open(dir.path_join("shaders/bb_0.gdshader"), FileAccess.WRITE)
	file.store_string(TEMPLATE)
	file.close()
	var blended := _state(5, 10, {"zwrite": 0})
	var shader := {"name": "Test/Order", "unity_id": "6", "properties": []}
	var queues: Array[int] = [2501, 2510, 2000, 3000, 3001, 4998, 4999, 5000, 2450]
	var materials: Dictionary = {}
	var entries: Array = []
	for i in queues.size():
		var id := str(30 + i)
		materials[id] = {"name": "m" + id, "shader": "Test/Order", "shader_id": "6", "translation": "bb", "states": [blended]}
		entries.append({"name": "m" + id, "unity_id": id, "render_queue": queues[i], "shader": shader, "floats": {}, "colors": {}, "textures": {}})
	materials["50"] = {"name": "opaque", "shader": "Test/Order", "shader_id": "6", "translation": "bb", "states": [_state(1, 0)]}
	entries.append({"name": "opaque", "unity_id": "50", "render_queue": 3005, "shader": shader, "floats": {}, "colors": {}, "textures": {}})
	var index := {
		"format": Translated.FORMAT,
		"translator": "kenbu-shader test",
		"materials": materials,
		"translations": {"bb": {"shader": "Test/Order", "keywords": [], "queue": "", "warnings": [],
			"passes": [{"file": "shaders/bb_0.gdshader", "light_mode": "", "state": blended, "uniforms": [], "unsupported": []}]}},
		"shaders": {"6": {"name": "Test/Order", "translations": ["bb"]}},
	}
	var out := FileAccess.open(dir.path_join("shaders.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(index))
	out.close()
	Translated.attach(entries, dir)
	var by_queue: Dictionary = {}
	for e: Dictionary in entries:
		var built := Translated.build(e, [], [])
		if built.is_empty():
			_expect(false, "queue %d builds" % int(e.render_queue))
			return
		by_queue[int(e.render_queue)] = (built.material as Material).render_priority
	var sorted := queues.duplicate()
	sorted.sort()
	var ordered := true
	for i in range(1, sorted.size()):
		ordered = ordered and int(by_queue[sorted[i]]) > int(by_queue[sorted[i - 1]])
	_expect(ordered, "blended materials keep Unity's queue order: %s" % [by_queue])
	_expect(int(by_queue[3000]) == 0 and int(by_queue[3001]) == 1, "Transparent and Transparent+1 keep queue - 3000: %s" % [by_queue])
	_expect(int(by_queue[2000]) == Material.RENDER_PRIORITY_MIN, "a blended Geometry material draws before every transparent queue: %s" % [by_queue])
	_expect(int(by_queue[5000]) == Material.RENDER_PRIORITY_MAX, "the highest queue keeps the top priority: %s" % [by_queue])
	_expect(int(by_queue[3005]) == 5, "an opaque material keeps queue - 3000: %s" % [by_queue])


func _compiles(code: String) -> PackedStringArray:
	_catch.take()
	var shader := Shader.new()
	shader.code = code
	return _catch.take()


## Real models: import, translate, load through the game's loader, compile everything.
func _check_models() -> void:
	var mirror := OS.get_environment("MODELSABER_DIR")
	if mirror.is_empty():
		mirror = OS.get_environment("HOME").path_join("projs/modelsaber")
	if not FileAccess.file_exists(Translated.translator_path()) or not FileAccess.file_exists(Loader.importer_path()):
		print("shaders_test: SKIP models (tools/bin/kenbu-shader or kenbu-import not built)")
		return
	if not DirAccess.dir_exists_absolute(mirror):
		print("shaders_test: SKIP models (no BeatMods mirror at %s)" % mirror)
		return
	var compiled := 0
	var translated := 0
	for id in FIXED:
		var bundle := _find(mirror, id)
		if bundle.is_empty():
			print("shaders_test: model %s is not in the mirror" % id)
			continue
		var dir := _work.path_join(id)
		var summary := Loader.import_bundle(bundle, dir)
		_expect(bool(summary.get("ok", false)), "%s imports: %s" % [id, summary.get("error", "")])
		var result := Translated.translate(bundle, dir)
		_expect(bool(result.get("ok", false)), "%s translates: %s" % [id, result.get("error", "")])
		# Every constant-buffer lane a program reads names a Unity variable (Unity 2021.2+ binds some
		# buffers only in the parameters common to all variants).
		var unnamed: PackedStringArray = []
		for t: Variant in (Translated.index(dir).get("translations", {}) as Dictionary).values():
			for p: Variant in (t as Dictionary).get("passes", []):
				for w: Variant in (p as Dictionary).get("warnings", []):
					if String(w).contains("names no variable"):
						unnamed.append("%s: %s" % [t.shader, w])
		_expect(unnamed.is_empty(), "%s: every constant-buffer lane is named: %s" % [id, unnamed.slice(0, 3)])
		var model := Loader.load_model(dir)
		if model == null:
			_expect(false, "%s loads" % id)
			continue
		_catch.take()
		Loader.finish(model)
		var errors := _catch.take()
		_expect(errors.is_empty(), "%s: materials compile: %s" % [id, errors.slice(0, 3)])
		var entries: Array = model.sidecar.get("materials", [])
		for m in entries.size():
			var entry: Dictionary = entries[m]
			if not entry.has("translated"):
				continue
			var built := Translated.build(entry, model.textures, model.sidecar.get("textures", []))
			_expect(not built.is_empty(), "%s: material %s builds from its translation" % [id, entry.get("name", "")])
			if built.is_empty():
				continue
			translated += 1
			var mat: Material = built.material
			while mat != null:
				var e := _compiles((mat as ShaderMaterial).shader.code)
				_expect(e.is_empty(), "%s: %s (%s) compiles: %s" % [id, entry.get("name", ""), built.shader, e.slice(0, 3)])
				compiled += 1
				mat = mat.next_pass
			var game: Dictionary = model.materials[m]
			var ported := Materials.KNOWN.has(String(built.shader)) or Materials.ports.has(String(built.shader))
			_expect(ported or bool(game.get("translated", false)),
				"%s: %s without a hand port is translated, not guessed" % [id, built.shader])
		model.release()
	print("shaders_test: %d materials translated, %d pass shaders compiled" % [translated, compiled])
	_expect(translated > 0, "the fixed models have translated materials")


func _find(mirror: String, id: String) -> String:
	for t: String in ["saber", "whacker", "bloq", "platform", "avatar"]:
		var folder := mirror.path_join(t).path_join(id)
		if not DirAccess.dir_exists_absolute(folder):
			continue
		for f in DirAccess.get_files_at(folder):
			if EXTENSIONS.has(f.get_extension().to_lower()):
				return folder.path_join(f)
	return ""
