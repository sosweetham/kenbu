"""The glTF 2.0 rules kenbu-import's output must follow, checked on its output folders
(development only, like compare.py).

  python -I gltf_rules.py <import_dir>...

Prints the problems of each folder that has any and a count; exits 1 when any folder has one.
Section numbers are the glTF 2.0 specification's.
"""
import json
import math
import os
import struct
import sys
from array import array

SIZES = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
COMPS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
FMT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}


def f32(x):
    """A JSON number as the single-precision float it stands for."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def sparse_parts(g, buf, a):
    """A sparse accessor's replaced element indices and their values, flat (3.6.2.3)."""
    s = a["sparse"]
    iv = g["bufferViews"][s["indices"]["bufferView"]]
    start = iv.get("byteOffset", 0) + s["indices"].get("byteOffset", 0)
    ct = s["indices"]["componentType"]
    indices = struct.unpack_from("<%d%s" % (s["count"], FMT[ct]), buf, start)
    vv = g["bufferViews"][s["values"]["bufferView"]]
    n = COMPS[a["type"]]
    start = vv.get("byteOffset", 0) + s["values"].get("byteOffset", 0)
    vals = array(FMT[a["componentType"]])
    vals.frombytes(buf[start:start + s["count"] * n * SIZES[a["componentType"]]])
    return indices, vals


def values(g, buf, index):
    """An accessor's components, flat, in a typed array: zeros without a view (3.6.2.1), then the
    sparse substitution (3.6.2.3)."""
    a = g["accessors"][index]
    n = COMPS[a["type"]]
    size = SIZES[a["componentType"]]
    out = array(FMT[a["componentType"]])
    if "bufferView" not in a:
        out.frombytes(bytes(a["count"] * n * size))
    else:
        v = g["bufferViews"][a["bufferView"]]
        stride = v.get("byteStride", size * n)
        start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        if stride == size * n:
            out.frombytes(buf[start:start + a["count"] * stride])
        else:
            for k in range(a["count"]):
                out.frombytes(buf[start + k * stride:start + k * stride + size * n])
    if "sparse" in a:
        indices, vals = sparse_parts(g, buf, a)
        for j, e in enumerate(indices):
            out[e * n:(e + 1) * n] = vals[j * n:(j + 1) * n]
    return out, n


def check(folder):
    problems = []
    g = json.load(open(os.path.join(folder, "model.gltf")))
    buf = open(os.path.join(folder, g["buffers"][0]["uri"]), "rb").read() if g.get("buffers") else b""
    for key in ("images", "materials", "textures", "samplers"):
        if key in g:
            problems.append(f"has {key}")
    views, accs = g.get("bufferViews", []), g.get("accessors", [])
    users = {}
    for i, a in enumerate(accs):
        users.setdefault(a.get("bufferView"), []).append(i)
    vertex_views, index_views, sparse_views = set(), set(), set()
    for a in accs:
        if "sparse" in a:
            sparse_views.update((a["sparse"]["indices"]["bufferView"], a["sparse"]["values"]["bufferView"]))
    for m in g.get("meshes", []):
        target_counts = set()
        for p in m["primitives"]:
            for a in p["attributes"].values():
                vertex_views.add(accs[a].get("bufferView"))
            target_counts.add(len(p.get("targets", [])))
            for t in p.get("targets", []):
                for a in t.values():
                    vertex_views.add(accs[a].get("bufferView"))
                    # 3.7.2.2: a target has its primitive's vertex count.
                    if accs[a]["count"] != accs[p["attributes"]["POSITION"]]["count"]:
                        problems.append("morph target count differs from its primitive's")
                # 3.7.2.2: a morph target's POSITION accessor has min and max, and they are the data's.
                if "POSITION" in t and ("min" not in accs[t["POSITION"]] or "max" not in accs[t["POSITION"]]):
                    problems.append("morph target POSITION without bounds")
                elif "POSITION" in t:
                    flat, _ = values(g, buf, t["POSITION"])
                    a = accs[t["POSITION"]]
                    for c in range(3):
                        column = flat[c::3]
                        if column and (min(column) != f32(a["min"][c]) or max(column) != f32(a["max"][c])):
                            problems.append("morph target POSITION bounds are not the data's")
                            break
            # 3.7.2.1: an indexed semantic's sets are numbered from 0 without gaps.
            for semantic in ("TEXCOORD", "COLOR", "JOINTS", "WEIGHTS"):
                sets = sorted(int(k.rsplit("_", 1)[1]) for k in p["attributes"] if k.startswith(semantic + "_"))
                if sets != list(range(len(sets))):
                    problems.append(f"{semantic} sets {sets} are not numbered from 0 without gaps")
            if "indices" in p:
                index_views.add(accs[p["indices"]]["bufferView"])
            if p.get("mode", 4) not in (0, 1, 2, 3, 4, 5, 6):
                problems.append("bad mode")
        # 3.7.2.2: every primitive of a mesh has the same number of morph targets.
        if len(target_counts) > 1:
            problems.append(f"mesh {m.get('name')} primitives differ in morph targets")
    vertex_views.discard(None)
    for v in vertex_views & index_views:
        problems.append(f"view {v} holds vertices and indices")
    for v in sparse_views & (vertex_views | index_views):
        problems.append(f"sparse view {v} also holds vertices or indices")
    for i, v in enumerate(views):
        if v.get("byteOffset", 0) + v["byteLength"] > len(buf):
            problems.append(f"view {i} past buffer")
        # 3.6.2.1: a view used by more than one vertex accessor defines byteStride.
        if i in vertex_views and len(users.get(i, [])) > 1 and "byteStride" not in v:
            problems.append(f"shared vertex view {i} without byteStride")
        if "byteStride" in v and (v["byteStride"] % 4 or not 4 <= v["byteStride"] <= 252):
            problems.append(f"view {i} bad stride {v['byteStride']}")
        if i in index_views and "byteStride" in v:
            problems.append(f"index view {i} has byteStride")
        # 3.6.2.3: views of sparse indices and values define neither byteStride nor target.
        if i in sparse_views and ("byteStride" in v or "target" in v):
            problems.append(f"sparse view {i} has byteStride or target")
    for i, a in enumerate(accs):
        esize = SIZES[a["componentType"]] * COMPS[a["type"]]
        if a["count"] < 1:
            problems.append(f"accessor {i} empty")
        if "bufferView" in a:
            v = views[a["bufferView"]]
            stride = v.get("byteStride", esize)
            off = v.get("byteOffset", 0) + a.get("byteOffset", 0)
            if off % SIZES[a["componentType"]]:
                problems.append(f"accessor {i} misaligned")
            if a.get("byteOffset", 0) + stride * (a["count"] - 1) + esize > v["byteLength"]:
                problems.append(f"accessor {i} past its view")
        if "sparse" not in a:
            continue
        # 3.6.2.3: 1 <= sparse count <= count; unsigned index type; indices strictly increasing
        # and inside the accessor; each part aligned and inside its view.
        s = a["sparse"]
        if not 1 <= s["count"] <= a["count"]:
            problems.append(f"accessor {i} sparse count {s['count']}")
            continue
        isize = SIZES.get(s["indices"]["componentType"], 0)
        if s["indices"]["componentType"] not in (5121, 5123, 5125):
            problems.append(f"accessor {i} sparse index type")
            continue
        for part, size, length in (("indices", isize, isize * s["count"]), ("values", SIZES[a["componentType"]], esize * s["count"])):
            pv = views[s[part]["bufferView"]]
            if (pv.get("byteOffset", 0) + s[part].get("byteOffset", 0)) % size:
                problems.append(f"accessor {i} sparse {part} misaligned")
            if s[part].get("byteOffset", 0) + length > pv["byteLength"]:
                problems.append(f"accessor {i} sparse {part} past their view")
        indices, _ = sparse_parts(g, buf, a)
        if any(b <= a_ for a_, b in zip(indices, indices[1:])) or indices[-1] >= a["count"]:
            problems.append(f"accessor {i} sparse indices not increasing or past its count")
    parents = {}
    nodes = g.get("nodes", [])
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            if c in parents:
                problems.append(f"node {c} has two parents")
            parents[c] = i
        # 5.25: rotation is a unit quaternion.
        q = n.get("rotation")
        if q is not None and abs(math.sqrt(sum(x * x for x in q)) - 1.0) > 1e-3:
            problems.append(f"node {i} rotation is not a unit quaternion")
    roots = g["scenes"][0]["nodes"]
    for r in roots:
        if r in parents:
            problems.append(f"scene root {r} has a parent")
    reached, pending = set(), list(roots)
    while pending:
        i = pending.pop()
        reached.add(i)
        pending.extend(nodes[i].get("children", []))
    if len(reached) != len(nodes):
        problems.append(f"{len(nodes) - len(reached)} nodes outside the scene")

    def ancestors(i):
        out = [i]
        while i in parents:
            i = parents[i]
            out.append(i)
        return out

    skins = g.get("skins", [])
    for s_i, s in enumerate(skins):
        joints = s["joints"]
        if len(set(joints)) != len(joints):
            problems.append(f"skin {s_i} repeats joints")
        if "inverseBindMatrices" in s:
            ibm, _ = values(g, buf, s["inverseBindMatrices"])
            if accs[s["inverseBindMatrices"]]["count"] != len(joints):
                problems.append(f"skin {s_i} IBM count")
            if not all(math.isfinite(x) for x in ibm):
                problems.append(f"skin {s_i} IBM not finite")
        sk = s.get("skeleton")
        if sk is not None and not all(sk in ancestors(j) for j in joints):
            problems.append(f"skin {s_i} skeleton {sk} is not a common root")
    for i, n in enumerate(nodes):
        if "mesh" in n:
            m = g["meshes"][n["mesh"]]
            skinned = any("JOINTS_0" in p["attributes"] for p in m["primitives"])
            if skinned != ("skin" in n):
                problems.append(f"node {i} skin/JOINTS_0 mismatch")
            targets = len(m["primitives"][0].get("targets", []))
            if "weights" in n and len(n["weights"]) != targets:
                problems.append(f"node {i} weights {len(n['weights'])} for {targets} targets")
            for p in m["primitives"]:
                pos = accs[p["attributes"]["POSITION"]]
                count = pos["count"]
                if "indices" in p:
                    a = accs[p["indices"]]
                    v = views[a["bufferView"]]
                    off = v.get("byteOffset", 0) + a.get("byteOffset", 0)
                    vals = struct.unpack_from("<%d%s" % (a["count"], FMT[a["componentType"]]), buf, off)
                    if max(vals) >= count:
                        problems.append(f"mesh {n['mesh']} index past vertex count")
                    if "max" in a and a["max"][0] != max(vals):
                        problems.append("index max wrong")
                # 3.7.2.1: POSITION has min and max, and they are the data's.
                if "min" not in pos or "max" not in pos:
                    problems.append("POSITION without bounds")
                else:
                    flat, _ = values(g, buf, p["attributes"]["POSITION"])
                    for c in range(3):
                        column = flat[c::3]
                        if column and (min(column) != f32(pos["min"][c]) or max(column) != f32(pos["max"][c])):
                            problems.append(f"mesh {n['mesh']} POSITION bounds are not the data's")
                            break
                # 3.7.3.3: joint indices point into the node's skin; joints with non-zero weights are
                # unique per vertex, and unused ones SHOULD be zero.
                if "JOINTS_0" in p["attributes"] and "skin" in n:
                    joints, _ = values(g, buf, p["attributes"]["JOINTS_0"])
                    if joints and max(joints) >= len(skins[n["skin"]]["joints"]):
                        problems.append(f"node {i} JOINTS_0 past its skin")
                    weights, _ = values(g, buf, p["attributes"]["WEIGHTS_0"])
                    for v in range(0, len(joints), 4):
                        live = [joints[v + k] for k in range(4) if weights[v + k] > 0]
                        if len(set(live)) != len(live):
                            problems.append(f"mesh {n['mesh']} repeats a joint within a vertex")
                            break
                        if any(joints[v + k] for k in range(4) if weights[v + k] == 0):
                            problems.append(f"mesh {n['mesh']} names a joint with zero weight")
                            break
        elif "skin" in n:
            problems.append(f"node {i} has a skin and no mesh")
    used = set(g.get("extensionsUsed", []))
    if any("KHR_node_visibility" in n.get("extensions", {}) for n in nodes) and "KHR_node_visibility" not in used:
        problems.append("KHR_node_visibility not declared")
    return problems


def main(folders):
    total = bad = 0
    for folder in folders:
        if not os.path.exists(os.path.join(folder, "model.gltf")):
            continue
        total += 1
        p = check(folder)
        if p:
            bad += 1
            print(os.path.basename(folder.rstrip("/")), sorted(set(p))[:6])
    print("checked", total, "folders,", bad, "with problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
