## Builds Kenbu's default avatar, assets/avatar/kenbu_avatar.glb, from Quaternius' CC0 "Universal
## Base Characters" glTF (assets/avatar/CREDITS.md): one self-contained GLB with the textures
## downscaled and JPEG-coded, and the body mesh split into "Body" and "HeadMesh" over the same
## vertices, so avatar/avatar.gd can hide the head from cameras at the player's eyes, and the
## arms lengthened to a person's (ARM_LENGTH). The rest of the skeleton, skin, geometry and
## materials are kept as they are.
##   godot --headless --xr-mode off --path . --script res://tools/motion_pack_avatar.gd -- \
##     "<pack>/Base Characters/Godot - UE/Superhero_Male_FullBody.gltf" assets/avatar/kenbu_avatar.glb
extends SceneTree

## Longest side of each texture by its image name, else DEFAULT_SIZE.
const SIZES: Dictionary = {"Eye": 256, "Hair": 512}
const DEFAULT_SIZE: int = 1024
const JPEG_QUALITY: float = 0.9
## A triangle belongs to the head when its corners' mean weight on the head joint is at least this.
const HEAD_SHARE: float = 0.5
const HEAD_JOINT: String = "Head"
## The pack's arms are a stylised figure's: shoulder to wrist is 0.29 of the eye height, where the
## players in public replays show hands 0.39 to 0.46 of theirs from their shoulders one frame in
## ten. A body whose arms cannot go where its player's do has to lean and step after every far
## cut, so the upper arms and forearms are made this much longer, along their length in the
## T-pose: shoulder to wrist becomes 0.33 of the eye height (a person's is about 0.34) and the
## arm span 1.09 of the height, a long-armed person's.
const ARM_LENGTH: float = 1.15

var json: Dictionary = {}
var bin: PackedByteArray = PackedByteArray()
var base_dir: String = ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: -- <in.gltf> <out.glb>")
		quit(2)
		return
	base_dir = args[0].get_base_dir()
	json = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var buffer: Dictionary = json["buffers"][0]
	bin = FileAccess.get_file_as_bytes(base_dir.path_join(buffer["uri"]))
	_pack_images()
	_lengthen_arms()
	_split_head()
	json["buffers"] = [{"byteLength": bin.size()}]
	json["asset"]["generator"] = "Kenbu tools/motion_pack_avatar.gd from Khronos glTF Blender I/O"
	_write_glb(args[1])
	print("motion_pack_avatar: wrote %s (%d bytes)" % [args[1], FileAccess.get_file_as_bytes(args[1]).size()])
	quit()


func _pack_images() -> void:
	for image_entry: Dictionary in json["images"]:
		var path := base_dir.path_join(String(image_entry["uri"]))
		if not FileAccess.file_exists(path):
			# The pack names two normal maps "<name>_png.png" but ships "<name>.png".
			path = path.replace("_png.png", ".png")
		var image := Image.load_from_file(path)
		var size: int = DEFAULT_SIZE
		for key: String in SIZES.keys():
			if String(image_entry.get("name", "")).contains(key):
				size = SIZES[key]
		if maxi(image.get_width(), image.get_height()) > size:
			image.resize(size, size, Image.INTERPOLATE_LANCZOS)
		image.convert(Image.FORMAT_RGB8)
		var bytes := image.save_jpg_to_buffer(JPEG_QUALITY)
		image_entry.erase("uri")
		image_entry["mimeType"] = "image/jpeg"
		image_entry["bufferView"] = _append_view(bytes)


## Splits the skinned mesh with the most vertices into body and head triangles.
func _split_head() -> void:
	var skin: Dictionary = json["skins"][0]
	var head_joint := -1
	for i in skin["joints"].size():
		if json["nodes"][int(skin["joints"][i])].get("name", "") == HEAD_JOINT:
			head_joint = i
	var body_node := -1
	var most := 0
	for n in json["nodes"].size():
		var node: Dictionary = json["nodes"][n]
		if node.has("mesh") and node.has("skin"):
			var primitive: Dictionary = json["meshes"][int(node["mesh"])]["primitives"][0]
			var count: int = json["accessors"][int(primitive["attributes"]["POSITION"])]["count"]
			if count > most:
				most = count
				body_node = n
	var node: Dictionary = json["nodes"][body_node]
	var mesh_index := int(node["mesh"])
	var primitive: Dictionary = json["meshes"][mesh_index]["primitives"][0]
	var joints := _read(int(primitive["attributes"]["JOINTS_0"]))
	var weights := _read(int(primitive["attributes"]["WEIGHTS_0"]))
	var indices := _read(int(primitive["indices"]))
	var head_weight := PackedFloat32Array()
	head_weight.resize(most)
	for v in most:
		for k in 4:
			if int(joints[v * 4 + k]) == head_joint:
				head_weight[v] += weights[v * 4 + k]
	var body := PackedInt32Array()
	var head := PackedInt32Array()
	for t in indices.size() / 3:
		var a := int(indices[t * 3])
		var b := int(indices[t * 3 + 1])
		var c := int(indices[t * 3 + 2])
		var target := head if (head_weight[a] + head_weight[b] + head_weight[c]) / 3.0 >= HEAD_SHARE else body
		target.append_array(PackedInt32Array([a, b, c]))
	primitive["indices"] = _index_accessor(body)
	json["meshes"][mesh_index]["name"] = "Body"
	node["name"] = "Body"
	var head_primitive := primitive.duplicate(true)
	head_primitive["indices"] = _index_accessor(head)
	# Not "Head": node names are unique in Godot's scene, and the head bone has that one.
	json["meshes"].append({"name": "HeadMesh", "primitives": [head_primitive]})
	json["nodes"].append({"name": "HeadMesh", "mesh": json["meshes"].size() - 1, "skin": int(node["skin"])})
	var head_node: int = json["nodes"].size() - 1
	# JSON numbers come back as floats.
	for parent: Dictionary in json["nodes"]:
		for child: float in parent.get("children", []):
			if int(child) == body_node:
				parent["children"].append(head_node)
				break
	print("motion_pack_avatar: %d body and %d head triangles" % [body.size() / 3, head.size() / 3])


## Lengthens both arms by ARM_LENGTH between the shoulder and the wrist: every vertex past the
## shoulder joint moves out along the T-pose's arm (X), the elbow and wrist joints move with them,
## and the bind matrices of the joints from the elbow down follow.
func _lengthen_arms() -> void:
	var skin: Dictionary = json["skins"][0]
	var joints: Array = skin["joints"]
	var binds := int(skin["inverseBindMatrices"])
	var joint_of: Dictionary = {}
	for i in joints.size():
		joint_of[int(joints[i])] = i
	var more := ARM_LENGTH - 1.0
	var shoulder_x := 0.0
	var wrist_x := 0.0
	for side: String in ["l", "r"]:
		var upper := _node_named("upperarm_" + side)
		var lower := _node_named("lowerarm_" + side)
		var hand := _node_named("hand_" + side)
		var shoulder := _bind_origin(binds, joint_of[upper])
		var elbow := _bind_origin(binds, joint_of[lower])
		var wrist := _bind_origin(binds, joint_of[hand])
		shoulder_x = absf(shoulder.x)
		wrist_x = absf(wrist.x)
		var elbow_moves := (elbow - shoulder) * more
		var wrist_moves := elbow_moves + (wrist - elbow) * more
		for node: int in [lower, hand]:
			var translation: Array = json["nodes"][node]["translation"]
			for k in 3:
				translation[k] = float(translation[k]) * ARM_LENGTH
		_move_bind(binds, joint_of[lower], elbow_moves)
		var below: Array[int] = [hand]
		while not below.is_empty():
			var node: int = below.pop_back()
			_move_bind(binds, joint_of[node], wrist_moves)
			for child in json["nodes"][node].get("children", []):
				if joint_of.has(int(child)):
					below.append(int(child))
	var done: Dictionary = {}
	for mesh: Dictionary in json["meshes"]:
		for primitive: Dictionary in mesh["primitives"]:
			var index := int(primitive["attributes"]["POSITION"])
			if done.has(index):
				continue
			done[index] = true
			var accessor: Dictionary = json["accessors"][index]
			var view: Dictionary = json["bufferViews"][int(accessor["bufferView"])]
			var offset := int(view.get("byteOffset", 0)) + int(accessor.get("byteOffset", 0))
			var stride := int(view.get("byteStride", 12))
			var widest := 0.0
			for i in int(accessor["count"]):
				var x := bin.decode_float(offset + i * stride)
				var out := absf(x)
				if out > wrist_x:
					out += (wrist_x - shoulder_x) * more
				elif out > shoulder_x:
					out = shoulder_x + (out - shoulder_x) * ARM_LENGTH
				bin.encode_float(offset + i * stride, signf(x) * out)
				widest = maxf(widest, out)
			if accessor.has("max") and accessor.has("min"):
				accessor["max"][0] = maxf(float(accessor["max"][0]), widest)
				accessor["min"][0] = minf(float(accessor["min"][0]), -widest)
	print("motion_pack_avatar: arms %.2f times as long between x %.3f and %.3f" % [ARM_LENGTH, shoulder_x, wrist_x])


func _node_named(node_name: String) -> int:
	for n in json["nodes"].size():
		if json["nodes"][n].get("name", "") == node_name:
			return n
	return -1


func _bind_offset(binds: int, joint: int) -> int:
	var accessor: Dictionary = json["accessors"][binds]
	var view: Dictionary = json["bufferViews"][int(accessor["bufferView"])]
	return int(view.get("byteOffset", 0)) + int(accessor.get("byteOffset", 0)) + joint * int(view.get("byteStride", 64))


## Where a joint is at rest: the origin of its inverse bind matrix's inverse.
func _bind_origin(binds: int, joint: int) -> Vector3:
	var at := _bind_offset(binds, joint)
	var basis := Basis()
	for column in 3:
		basis[column] = Vector3(bin.decode_float(at + column * 16), bin.decode_float(at + column * 16 + 4), bin.decode_float(at + column * 16 + 8))
	var origin := Vector3(bin.decode_float(at + 48), bin.decode_float(at + 52), bin.decode_float(at + 56))
	return Transform3D(basis, origin).affine_inverse().origin


## Moves a joint's rest by `by`: its inverse bind matrix M becomes M * translate(-by).
func _move_bind(binds: int, joint: int, by: Vector3) -> void:
	var at := _bind_offset(binds, joint)
	for row in 3:
		var change := 0.0
		for column in 3:
			change += bin.decode_float(at + column * 16 + row * 4) * by[column]
		bin.encode_float(at + 48 + row * 4, bin.decode_float(at + 48 + row * 4) - change)


## The values of an accessor as floats, normalised integers unscaled.
func _read(accessor_index: int) -> PackedFloat32Array:
	var accessor: Dictionary = json["accessors"][accessor_index]
	var view: Dictionary = json["bufferViews"][int(accessor["bufferView"])]
	var offset := int(view.get("byteOffset", 0)) + int(accessor.get("byteOffset", 0))
	var components := {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[accessor["type"]] as int
	var kind := int(accessor["componentType"])
	var size := {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}[kind] as int
	var stride := int(view.get("byteStride", components * size))
	var out := PackedFloat32Array()
	for i in int(accessor["count"]):
		for k in components:
			var at := offset + i * stride + k * size
			match kind:
				5121:
					out.append(bin[at])
				5123:
					out.append(bin.decode_u16(at))
				5125:
					out.append(bin.decode_u32(at))
				5126:
					out.append(bin.decode_float(at))
				_:
					out.append(0.0)
	return out


func _index_accessor(indices: PackedInt32Array) -> int:
	var bytes := PackedByteArray()
	bytes.resize(indices.size() * 2)
	for i in indices.size():
		bytes.encode_u16(i * 2, indices[i])
	var view := _append_view(bytes, 34963)
	json["accessors"].append({"bufferView": view, "componentType": 5123, "count": indices.size(), "type": "SCALAR"})
	return json["accessors"].size() - 1


func _append_view(bytes: PackedByteArray, target: int = 0) -> int:
	while bin.size() % 4 != 0:
		bin.append(0)
	var view := {"buffer": 0, "byteOffset": bin.size(), "byteLength": bytes.size()}
	if target != 0:
		view["target"] = target
	bin.append_array(bytes)
	json["bufferViews"].append(view)
	return json["bufferViews"].size() - 1


func _write_glb(path: String) -> void:
	var text := JSON.stringify(json).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	while bin.size() % 4 != 0:
		bin.append(0)
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, 12 + 8 + text.size() + 8 + bin.size())
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, text.size())
	header.encode_u32(4, 0x4E4F534A)
	out.append_array(header)
	out.append_array(text)
	header.encode_u32(0, bin.size())
	header.encode_u32(4, 0x004E4942)
	out.append_array(header)
	out.append_array(bin)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(out)
	file.close()
