"""UnityPy as an independent oracle for kenbu-import (development only; Kenbu never ships it).

  python -I compare.py oracle <bundle> <out.json>
      What Unity would show, from UnityPy's reading of the bundle, for tests/content_test.gd:
      every GameObject (name, active, layer, parent, children), every mesh renderer's draws in
      world space at rest (per draw: vertices used, bounds and centroid, X mirrored as the importer
      mirrors it; skinned meshes skinned with Unity's formula), textures (format, size, mips and a
      grid of decoded pixels in Unity's row order), materials, UnityEvent call targets and the
      humanoid bone map.
  python -I compare.py check <bundle> <import_dir>
      The importer's output against UnityPy, element by element: every vertex attribute and
      triangle of every glTF primitive, every morph target (a blend shape channel's last frame)
      and every renderer's morph weights, every node's name, mirrored transform, visibility and
      children, every DDS payload against Unity's stored image data, every PNG pixel. Prints one
      JSON line; exits 1 when anything differs.

Needs UnityPy 1.25 and Pillow (a venv: python -m venv v && v/bin/pip install UnityPy==1.25.4).
Model files are third-party data: keep oracles and outputs outside the repository.
"""
import hashlib
import json
import math
import os
import struct
import sys

import UnityPy
from UnityPy.enums import TextureFormat
from UnityPy.helpers.MeshHelper import MeshHandler
from PIL import Image

HUMAN_BONES = ["Hips", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot",
               "Spine", "Chest", "UpperChest", "Neck", "Head", "LeftShoulder", "RightShoulder", "LeftUpperArm",
               "RightUpperArm", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand", "LeftToes", "RightToes",
               "LeftEye", "RightEye", "Jaw"]
FINGERS = ["ThumbProximal", "ThumbIntermediate", "ThumbDistal", "IndexProximal", "IndexIntermediate", "IndexDistal",
           "MiddleProximal", "MiddleIntermediate", "MiddleDistal", "RingProximal", "RingIntermediate", "RingDistal",
           "LittleProximal", "LittleIntermediate", "LittleDistal"]
GRID = 16


def load(path):
    """UnityPy environment of a bundle or of a .whacker's PC bundle."""
    with open(path, "rb") as f:
        head = f.read(4)
    if head == b"PK\x03\x04":
        import zipfile
        z = zipfile.ZipFile(path)
        package = json.loads(next(z.read(n) for n in z.namelist() if n.lower().endswith(".json")))
        return UnityPy.load(z.read(package["pcFileName"]))
    return UnityPy.load(path)


class Bundle:
    def __init__(self, path):
        self.env = load(path)
        self.objs = {o.path_id: o for o in self.env.objects}
        self.cache = {}
        self.world_cache = {}

    def read(self, pid):
        if pid not in self.cache:
            self.cache[pid] = self.objs[pid].read()
        return self.cache[pid]

    def kind(self, pid):
        o = self.objs.get(pid)
        return o.type.name if o is not None else None

    def components(self, go):
        out = []
        for c in go.m_Component:
            ptr = c.component if hasattr(c, "component") else c[1]
            out.append(ptr.m_PathID)
        return out

    def transform_of(self, go):
        for pid in self.components(go):
            if self.kind(pid) in ("Transform", "RectTransform"):
                return pid
        return None

    def local(self, tid):
        t = self.read(tid)
        p, q, s = t.m_LocalPosition, t.m_LocalRotation, t.m_LocalScale
        x, y, z, w = q.x, q.y, q.z, q.w
        r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
             [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
             [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
        return [[r[i][0] * s.x, r[i][1] * s.y, r[i][2] * s.z, (p.x, p.y, p.z)[i]] for i in range(3)] + [[0, 0, 0, 1]]

    def world(self, tid):
        if tid not in self.world_cache:
            m = self.local(tid)
            father = self.read(tid).m_Father.m_PathID
            self.world_cache[tid] = mul(self.world(father), m) if father else m
        return self.world_cache[tid]

    def active_in_hierarchy(self, tid):
        while tid:
            t = self.read(tid)
            if not self.read(t.m_GameObject.m_PathID).m_IsActive:
                return False
            tid = t.m_Father.m_PathID
        return True

    def script_class(self, mb):
        try:
            s = mb.m_Script.read()
        except Exception:
            return "MonoBehaviour"
        return f"{s.m_Namespace}.{s.m_ClassName}" if s.m_Namespace else s.m_ClassName


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def apply(m, p):
    return [m[r][0] * p[0] + m[r][1] * p[1] + m[r][2] * p[2] + m[r][3] for r in range(3)]


def gameobjects(b):
    out = {}
    for o in b.env.objects:
        if o.type.name != "GameObject":
            continue
        go = b.read(o.path_id)
        tid = b.transform_of(go)
        if tid is None:
            continue
        t = b.read(tid)
        father = t.m_Father.m_PathID
        parent = b.read(father).m_GameObject.m_PathID if father else None
        children = [b.read(c.m_PathID).m_GameObject.m_PathID for c in t.m_Children if c.m_PathID in b.objs]
        out[str(o.path_id)] = {"name": go.m_Name, "active": bool(go.m_IsActive), "layer": int(go.m_Layer),
                               "parent": str(parent) if parent else None, "children": [str(c) for c in children]}
    return out


def renderers(b):
    """Every MeshRenderer and SkinnedMeshRenderer: per material slot, the submesh it draws in world
    space at rest (Unity draws slot k with submesh min(k, n - 1); slots past the materials draw
    nothing)."""
    out = {}
    handlers = {}
    for o in b.env.objects:
        if o.type.name not in ("MeshRenderer", "SkinnedMeshRenderer"):
            continue
        r = b.read(o.path_id)
        go_id = r.m_GameObject.m_PathID
        go = b.read(go_id)
        tid = b.transform_of(go)
        if o.type.name == "SkinnedMeshRenderer":
            mesh_ptr = r.m_Mesh
        else:
            mf = next((pid for pid in b.components(go) if b.kind(pid) == "MeshFilter"), None)
            mesh_ptr = b.read(mf).m_Mesh if mf else None
        entry = {"class": o.type.name, "enabled": bool(r.m_Enabled), "active": b.active_in_hierarchy(tid),
                 "materials": len(r.m_Materials), "draws": []}
        out[str(go_id)] = entry
        if mesh_ptr is None or mesh_ptr.m_PathID == 0:
            entry["mesh"] = None
            continue
        if mesh_ptr.m_FileID != 0:
            entry["mesh"] = {"external": mesh_ptr.m_PathID}
            continue
        mid = mesh_ptr.m_PathID
        m = b.read(mid)
        if mid not in handlers:
            try:
                h = MeshHandler(m)
                h.process()
                handlers[mid] = (h, h.get_triangles())
            except Exception as e:
                handlers[mid] = (None, str(e))
        h, tris = handlers[mid]
        if h is None:
            entry["mesh"] = {"name": m.m_Name, "unity_py_error": tris}
            continue
        entry["mesh"] = {"name": m.m_Name, "vertices": len(h.m_Vertices or [])}
        if not h.m_Vertices:
            continue
        bones = [x.m_PathID for x in getattr(r, "m_Bones", None) or []]
        skinned = o.type.name == "SkinnedMeshRenderer" and bones and (h.m_BoneWeights or h.m_BoneIndices)
        entry["skinned"] = bool(skinned)
        if skinned:
            binds = [[[getattr(x, f"e{i}{j}") for j in range(4)] for i in range(4)] for x in m.m_BindPose]
            skin = [mul(b.world(bid), binds[i]) if bid and bid in b.objs and i < len(binds) else None
                    for i, bid in enumerate(bones)]
            weights = [tuple(w) for w in h.m_BoneWeights] if h.m_BoneWeights else [(1.0,)] * len(h.m_Vertices)
            indices = [tuple(x) if isinstance(x, (list, tuple)) else (x,) for x in h.m_BoneIndices]
        else:
            local_to_world = b.world(tid)
        subs = m.m_SubMeshes
        for k in range(len(r.m_Materials)):
            si = min(k, len(subs) - 1)
            if si < 0 or not tris[si]:
                continue
            base = getattr(subs[si], "baseVertex", 0) or 0
            used = sorted({i + base for t in tris[si] for i in t})
            lo, hi, total = [math.inf] * 3, [-math.inf] * 3, [0.0] * 3
            missing = False
            for v in used:
                p = h.m_Vertices[v]
                if skinned:
                    q = [0.0, 0.0, 0.0]
                    ws = weights[v]
                    s = sum(w for w in ws) or 1.0
                    for j, w in zip(indices[v], ws):
                        if w > 0 and j < len(skin) and skin[j] is not None:
                            x = apply(skin[j], p)
                            for c in range(3):
                                q[c] += w / s * x[c]
                        elif w > 0:
                            # Unity's handling of a null bone is undocumented: not comparable.
                            missing = True
                else:
                    q = apply(local_to_world, p)
                q = [-q[0], q[1], q[2]]
                for c in range(3):
                    lo[c] = min(lo[c], q[c])
                    hi[c] = max(hi[c], q[c])
                    total[c] += q[c]
            entry["draws"].append({"slot": k, "submesh": si, "used": len(used), "min": lo, "max": hi,
                                   "mean": [x / len(used) for x in total], "missing_bones": missing})
    return out


def pixel_grid(img_rows_unity, w, h):
    """GRID x GRID pixels at fixed coordinates, rows in Unity's stored order (row 0 = bottom)."""
    px = img_rows_unity.load()
    out = []
    for j in range(GRID):
        y = (2 * j + 1) * h // (2 * GRID)
        for i in range(GRID):
            x = (2 * i + 1) * w // (2 * GRID)
            out.append(list(px[x, y]))
    return out


def textures(b):
    out = {}
    for o in b.env.objects:
        if o.type.name not in ("Texture2D", "Cubemap"):
            continue
        t = b.read(o.path_id)
        entry = {"name": t.m_Name, "format": TextureFormat(int(t.m_TextureFormat)).name, "width": t.m_Width, "height": t.m_Height,
                 "mips": t.m_MipCount, "images": getattr(t, "m_ImageCount", 1) or 1, "srgb": getattr(t, "m_ColorSpace", 1) == 1}
        try:
            if entry["images"] == 1:
                img = t.image.transpose(Image.FLIP_TOP_BOTTOM).convert("RGBA")
                entry["grid"] = pixel_grid(img, t.m_Width, t.m_Height)
        except Exception as e:
            entry["decode_error"] = str(e)
        out[str(o.path_id)] = entry
    return out


def materials(b):
    out = {}
    for o in b.env.objects:
        if o.type.name != "Material":
            continue
        m = b.read(o.path_id)
        shader = ""
        try:
            if m.m_Shader.m_PathID and m.m_Shader.m_FileID == 0:
                sh = m.m_Shader.read()
                shader = sh.m_ParsedForm.m_Name if getattr(sh, "m_ParsedForm", None) else sh.m_Name
        except Exception:
            pass
        out[str(o.path_id)] = {"name": m.m_Name, "shader": shader}
    return out


def event_calls(b):
    """Every UnityEvent persistent call: its component, field path, target object and method."""
    calls = []
    for o in b.env.objects:
        if o.type.name != "MonoBehaviour":
            continue
        try:
            tree = o.read_typetree()
        except Exception:
            continue

        def walk(node, path):
            if isinstance(node, dict):
                if "m_PersistentCalls" in node and isinstance(node["m_PersistentCalls"], dict):
                    for i, call in enumerate(node["m_PersistentCalls"].get("m_Calls", [])):
                        target = call.get("m_Target", {})
                        pid = target.get("m_PathID", 0)
                        if not pid or target.get("m_FileID", 0) != 0:
                            continue
                        kind = b.kind(pid)
                        info = {"component": str(o.path_id), "path": path + ["m_PersistentCalls", "m_Calls", i],
                                "method": call.get("m_MethodName", ""), "target": str(pid), "target_class": kind}
                        if kind and kind != "GameObject" and pid in b.objs:
                            target_obj = b.read(pid)
                            go = getattr(target_obj, "m_GameObject", None)
                            info["target_gameobject"] = str(go.m_PathID) if go is not None else None
                            if kind == "MonoBehaviour":
                                info["target_class"] = b.script_class(target_obj)
                        calls.append(info)
                for k, v in node.items():
                    walk(v, path + [k])
            elif isinstance(node, list):
                for i, v in enumerate(node):
                    walk(v, path + [i])

        walk(tree, [])
    return calls


def humanoid(b):
    out = []
    for o in b.env.objects:
        if o.type.name != "Animator":
            continue
        a = b.read(o.path_id)
        if not a.m_Avatar.m_PathID or a.m_Avatar.m_FileID != 0:
            continue
        av = b.objs[a.m_Avatar.m_PathID].read_typetree()
        human = av["m_Avatar"]["m_Human"]["data"]
        ids = human["m_Skeleton"]["data"]["m_ID"]
        tos = dict(av["m_TOS"])
        root_t = b.transform_of(b.read(a.m_GameObject.m_PathID))

        def find(path):
            t = root_t
            for part in [p for p in path.split("/") if p]:
                nxt = None
                for c in b.read(t).m_Children:
                    if b.read(b.read(c.m_PathID).m_GameObject.m_PathID).m_Name == part:
                        nxt = c.m_PathID
                        break
                if nxt is None:
                    return None
                t = nxt
            return str(b.read(t).m_GameObject.m_PathID)

        bones = {}
        for i, idx in enumerate(human["m_HumanBoneIndex"]):
            if idx >= 0 and i < len(HUMAN_BONES) and idx < len(ids) and ids[idx] in tos:
                go = find(tos[ids[idx]])
                if go:
                    bones[HUMAN_BONES[i]] = go
        for side, key, has in (("Left", "m_LeftHand", "m_HasLeftHand"), ("Right", "m_RightHand", "m_HasRightHand")):
            if human.get(has):
                for i, idx in enumerate(human[key]["data"]["m_HandBoneIndex"]):
                    if idx >= 0 and i < len(FINGERS) and idx < len(ids) and ids[idx] in tos:
                        go = find(tos[ids[idx]])
                        if go:
                            bones[side + FINGERS[i]] = go
        out.append({"animator_gameobject": str(a.m_GameObject.m_PathID), "bones": bones})
    return out


def oracle(bundle, out_path):
    b = Bundle(bundle)
    with open(bundle, "rb") as f:
        md5 = hashlib.md5(f.read()).hexdigest()
    counts = {}
    for o in b.env.objects:
        counts[o.type.name] = counts.get(o.type.name, 0) + 1
    result = {"file": os.path.basename(bundle), "md5": md5, "counts": counts, "gameobjects": gameobjects(b),
              "renderers": renderers(b), "textures": textures(b), "materials": materials(b),
              "events": event_calls(b), "humanoids": humanoid(b)}
    with open(out_path, "w") as f:
        json.dump(result, f)
    print(json.dumps({"ok": True, "file": result["file"], "gameobjects": len(result["gameobjects"]),
                      "renderers": len(result["renderers"]), "textures": len(result["textures"]), "events": len(result["events"])}))


def last_frames(m):
    """Per blend shape channel with frames: (channel index, last frame's weight, {vertex: mirrored
    delta})."""
    shapes = m.m_Shapes
    out = []
    for ci, c in enumerate(shapes.channels):
        if c.frameCount <= 0:
            continue
        last = c.frameIndex + c.frameCount - 1
        f = shapes.shapes[last]
        deltas = {v.index: (-v.vertex.x, v.vertex.y, v.vertex.z)
                  for v in shapes.vertices[f.firstVertex:f.firstVertex + f.vertexCount]}
        out.append((ci, shapes.fullWeights[last], deltas))
    return out


def morphs(b, G, S, acc, maxdiff, prob):
    """Morph targets against each channel's last frame; node weights against the renderer's
    m_BlendShapeWeights over that frame's weight (Unity moves a vertex by weight / frame weight)."""
    stat = {"targets": 0, "targets_ok": 0, "max_delta": 0.0, "weighted": 0, "weighted_ok": 0}
    mesh_table = S.get("meshes", [])
    frames_of = {}
    for gi, gm in enumerate(G.get("meshes", [])):
        entry = mesh_table[gm["extras"]["mesh"]]
        if entry.get("builtin") or not any(p.get("targets") for p in gm["primitives"]):
            continue
        frames = frames_of.setdefault(gi, last_frames(b.read(int(entry["unity_id"]))))
        for prim in gm["primitives"]:
            for t, target in enumerate(prim.get("targets", [])):
                stat["targets"] += 1
                got, a = acc(target["POSITION"])
                # A target covers the vertices its primitive's POSITION accessor does.
                pos = G["accessors"][prim["attributes"]["POSITION"]]
                first = pos.get("byteOffset", 0) // G["bufferViews"][pos["bufferView"]].get("byteStride", 12)
                deltas = frames[t][2] if t < len(frames) else {}
                e = maxdiff(got, [deltas.get(first + k, (0.0, 0.0, 0.0)) for k in range(a["count"])])
                stat["max_delta"] = max(stat["max_delta"], e)
                if t < len(frames) and len(prim["targets"]) == len(frames) and e < 1e-5:
                    stat["targets_ok"] += 1
                else:
                    prob(f"{gm['name']} target {t}: differs from the channel's last frame")
    for r in S.get("renderers", []):
        node = G["nodes"][r.get("instance", r["node"])]
        if "weights" not in node:
            continue
        stat["weighted"] += 1
        renderer = b.read(int(S["components"][r["component"]]["unity_id"]))
        frames = frames_of.get(node["mesh"]) or last_frames(b.read(int(mesh_table[r["mesh"]]["unity_id"])))
        unity = list(renderer.m_BlendShapeWeights or [])
        want = [(unity[ci] if ci < len(unity) else 0.0) / (w if w else 100.0) for ci, w, _ in frames]
        if len(want) == len(node["weights"]) and maxdiff([node["weights"]], [want]) < 1e-6:
            stat["weighted_ok"] += 1
        else:
            prob(f"{node['name']}: morph weights {node['weights'][:4]} differ from Unity's {want[:4]}")
    return stat


def check(bundle, out_dir):
    """Element-wise comparison of the importer's output with UnityPy (after the research
    verification's verify_gltf.py, adapted to strided views and the sidecar's texture table)."""
    b = Bundle(bundle)
    G = json.load(open(os.path.join(out_dir, "model.gltf")))
    S = json.load(open(os.path.join(out_dir, "sidecar.json")))
    binp = os.path.join(out_dir, "model.bin")
    BIN = open(binp, "rb").read() if os.path.exists(binp) else b""
    problems = []
    R = {"file": os.path.basename(bundle)}

    def prob(s):
        if len(problems) < 20:
            problems.append(s)

    def acc(i):
        """An accessor's elements: from its view, or zeros without one; then a sparse accessor's
        replaced elements (glTF 2.0 3.6.2.3)."""
        a = G["accessors"][i]
        c = {5126: ("f", 4), 5123: ("H", 2), 5125: ("I", 4)}[a["componentType"]]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
        if "bufferView" in a:
            v = G["bufferViews"][a["bufferView"]]
            stride = v.get("byteStride", c[1] * n)
            base = v.get("byteOffset", 0) + a.get("byteOffset", 0)
            out = [struct.unpack_from(f"<{n}{c[0]}", BIN, base + k * stride) for k in range(a["count"])]
        else:
            out = [(0,) * n] * a["count"]
        if "sparse" in a:
            sp = a["sparse"]
            iv = G["bufferViews"][sp["indices"]["bufferView"]]
            ic = {5121: "B", 5123: "H", 5125: "I"}[sp["indices"]["componentType"]]
            at = struct.unpack_from(f"<{sp['count']}{ic}", BIN, iv.get("byteOffset", 0) + sp["indices"].get("byteOffset", 0))
            vv = G["bufferViews"][sp["values"]["bufferView"]]
            base = vv.get("byteOffset", 0) + sp["values"].get("byteOffset", 0)
            for j, e in enumerate(at):
                out[e] = struct.unpack_from(f"<{n}{c[0]}", BIN, base + j * c[1] * n)
        return out, a

    def maxdiff(x, y):
        m = 0.0
        for p, q in zip(x, y):
            for s, t in zip(p, q):
                m = max(m, abs(s - t))
        return m

    def norm3(v):
        l = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2) or 1e-12
        return (v[0] / l, v[1] / l, v[2] / l)

    stats = {"primitives": 0, "ok": 0, "max_pos": 0.0, "max_nrm": 0.0, "max_uv": 0.0, "max_w": 0.0}
    mesh_table = S.get("meshes", [])
    for gm in G.get("meshes", []):
        entry = mesh_table[gm["extras"]["mesh"]]
        if entry.get("builtin"):
            continue
        m = b.read(int(entry["unity_id"]))
        h = MeshHandler(m)
        h.process()
        tris = h.get_triangles()
        subs = m.m_SubMeshes
        for prim in gm["primitives"]:
            stats["primitives"] += 1
            k = prim["extras"]["draw"]
            si = min(k, len(subs) - 1)
            A = prim["attributes"]
            pos, a = acc(A["POSITION"])
            view = G["bufferViews"][a["bufferView"]]
            fv = a.get("byteOffset", 0) // view.get("byteStride", 12)
            vc = a["count"]
            ok = True
            e = maxdiff(pos, [(-v[0], v[1], v[2]) for v in h.m_Vertices[fv:fv + vc]])
            stats["max_pos"] = max(stats["max_pos"], e)
            ok &= e < 1e-5
            if "NORMAL" in A:
                n_ = acc(A["NORMAL"])[0]
                e = maxdiff(n_, [(-x[0], x[1], x[2]) for x in (norm3(q) for q in h.m_Normals[fv:fv + vc])])
                stats["max_nrm"] = max(stats["max_nrm"], e)
                ok &= e < 1e-4
            for key, src in (("TEXCOORD_0", h.m_UV0), ("TEXCOORD_1", h.m_UV1)):
                if key in A:
                    e = maxdiff(acc(A[key])[0], [(u[0], u[1]) for u in src[fv:fv + vc]])
                    stats["max_uv"] = max(stats["max_uv"], e)
                    ok &= e < 1e-5
                elif src:
                    ok = False
                    prob(f"{m.m_Name}: {key} missing")
            if "WEIGHTS_0" in A and h.m_BoneWeights:
                # Each vertex's total weight per bone: glTF lists a joint once (3.7.3.3) where Unity
                # may list a bone twice, and sums them.
                w = acc(A["WEIGHTS_0"])[0]
                j = acc(A["JOINTS_0"])[0]
                e = 0.0
                for k, (x, bones) in enumerate(zip(h.m_BoneWeights[fv:fv + vc], h.m_BoneIndices[fv:fv + vc])):
                    x = [max(0.0, y) for y in tuple(x) + (0.0,) * (4 - len(x))]
                    s = sum(x)
                    sums = {}
                    for bone, y in zip(tuple(bones) + (0,) * (4 - len(bones)), x if s > 0 else (1.0, 0.0, 0.0, 0.0)):
                        sums[bone] = sums.get(bone, 0.0) + (y / s if s > 0 else y)
                    for bone, y in zip(j[k], w[k]):
                        sums[bone] = sums.get(bone, 0.0) - y
                    e = max([e] + [abs(y) for y in sums.values()])
                stats["max_w"] = max(stats["max_w"], e)
                ok &= e < 1e-5
            idx = [x[0] + fv for x in acc(prim["indices"])[0]]
            if prim.get("mode", 4) == 4:
                got = [(idx[t], idx[t + 2], idx[t + 1]) for t in range(0, len(idx), 3)]
                exp = [tuple(x + (getattr(subs[si], "baseVertex", 0) or 0) for x in t) for t in tris[si]]
                if got != exp:
                    ok = False
                    prob(f"{m.m_Name} draw {k}: triangles differ ({len(got)} vs {len(exp)})")
            if ok:
                stats["ok"] += 1
            else:
                prob(f"{m.m_Name} draw {k}: attributes differ")
    R["meshes"] = stats
    R["morphs"] = morphs(b, G, S, acc, maxdiff, prob)

    nodes = G["nodes"]
    h_ok = h_bad = 0
    for i, n in enumerate(nodes):
        uid = n.get("extras", {}).get("unity_id")
        if not uid or n.get("extras", {}).get("helper"):
            continue
        go = b.read(int(uid))
        t = b.read(b.transform_of(go))
        p, r, s = t.m_LocalPosition, t.m_LocalRotation, t.m_LocalScale
        good = n["name"] == go.m_Name
        good &= max(abs(x - y) for x, y in zip(n["translation"], (-p.x, p.y, p.z))) < 1e-6
        good &= max(abs(x - y) for x, y in zip(n["rotation"], (r.x, -r.y, -r.z, r.w))) < 1e-6
        good &= max(abs(x - y) for x, y in zip(n["scale"], (s.x, s.y, s.z))) < 1e-6
        hidden = n.get("extensions", {}).get("KHR_node_visibility", {}).get("visible", True) is False
        good &= hidden == ((not go.m_IsActive) or n.get("extras", {}).get("prefab_root", False))
        kids_exp = [str(b.read(c.m_PathID).m_GameObject.m_PathID) for c in t.m_Children]
        kids_got = [nodes[c]["extras"]["unity_id"] for c in n.get("children", [])
                    if nodes[c].get("extras", {}).get("unity_id") and not nodes[c]["extras"].get("helper")]
        good &= kids_exp == kids_got
        if good:
            h_ok += 1
        else:
            h_bad += 1
            prob(f"node {go.m_Name}: hierarchy differs")
    total_gos = sum(1 for o in b.env.objects if o.type.name == "GameObject")
    R["hierarchy"] = {"ok": h_ok, "bad": h_bad, "gameobjects": total_gos}
    if h_ok + h_bad != total_gos:
        prob(f"{total_gos} GameObjects, {h_ok + h_bad} nodes")

    t_stat = {"dds": 0, "dds_exact": 0, "png": 0, "png_exact": 0, "png_maxdiff": 0}
    for t in S.get("textures", []):
        if t.get("error") or not t.get("files"):
            continue
        tex = b.read(int(t["unity_id"]))
        raw = bytes(tex.get_image_data()) if hasattr(tex, "get_image_data") else bytes(tex.image_data)
        faces = len(t["files"])
        per_face = len(raw) // faces if faces else 0
        for fi, f in enumerate(t["files"]):
            data = open(os.path.join(out_dir, f), "rb").read()
            if f.endswith(".dds"):
                t_stat["dds"] += 1
                header = 128 + (20 if data[84:88] == b"DX10" else 0)
                payload = data[header:]
                face = raw[fi * per_face:fi * per_face + len(payload)]
                if payload == face:
                    t_stat["dds_exact"] += 1
                else:
                    prob(f"dds {t['name']}: payload differs from Unity's stored data")
            elif faces == 1:
                t_stat["png"] += 1
                mine = Image.open(os.path.join(out_dir, f)).convert("RGBA").tobytes()
                try:
                    ref = tex.image.transpose(Image.FLIP_TOP_BOTTOM).convert("RGBA").tobytes()
                except Exception as e:
                    prob(f"png {t['name']}: UnityPy cannot decode ({e})")
                    continue
                d = max((abs(x - y) for x, y in zip(ref, mine)), default=0) if len(ref) == len(mine) else 255
                t_stat["png_maxdiff"] = max(t_stat["png_maxdiff"], d)
                if d == 0:
                    t_stat["png_exact"] += 1
                else:
                    prob(f"png {t['name']} {t['format']}: max channel difference {d}")
    R["textures"] = t_stat
    R["problems"] = problems
    R["ok"] = not problems
    print(json.dumps(R))
    return 0 if R["ok"] else 1


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "oracle":
        oracle(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__)
        sys.exit(2)
