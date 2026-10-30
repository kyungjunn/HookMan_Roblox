"""Patch Luau Source chunks; preserve all unrelated binary chunks byte-for-byte.
Requires zstandard and lz4. Run from the project root after tests pass.
"""
import argparse
import hashlib
import pathlib
import struct
import zstandard
import lz4.block


class Reader:
    def __init__(self, data):
        self.data, self.position = data, 0

    def take(self, size):
        result = self.data[self.position:self.position + size]
        if len(result) != size:
            raise ValueError("Truncated Roblox chunk")
        self.position += size
        return result

    def uint(self):
        return struct.unpack("<I", self.take(4))[0]

    def string(self):
        return self.take(self.uint())

    def refs(self, count):
        data, result, previous = self.take(count * 4), [], 0
        for i in range(count):
            value = int.from_bytes(bytes(data[i + k * count] for k in range(4)), "big")
            previous += (value >> 1) ^ -(value & 1)
            result.append(previous)
        return result


def uint(value):
    return struct.pack("<I", value)


def string(value):
    data = value.encode() if isinstance(value, str) else value
    return uint(len(data)) + data


def refs(values):
    columns, previous = [bytearray() for _ in range(4)], 0
    for value in values:
        delta = value - previous
        encoded = ((delta << 1) ^ (delta >> 31)).to_bytes(4, "big")
        for i in range(4):
            columns[i].append(encoded[i])
        previous = value
    return b"".join(columns)


def chunk(tag, data):
    packed = zstandard.ZstdCompressor(level=3).compress(data)
    return tag + struct.pack("<III", len(packed), len(data), 0) + packed


def decode(path):
    data = pathlib.Path(path).read_bytes()
    if data[:14] != b"<roblox!\x89\xff\r\n\x1a\n":
        raise ValueError("Not a Roblox binary place")
    items, position = [], 32
    while position < len(data):
        start = position
        tag = data[position:position + 4]
        compressed, size, _ = struct.unpack_from("<III", data, position + 4)
        position += 16
        raw = data[position:position + (compressed or size)]
        position += compressed or size
        if compressed:
            raw = (zstandard.ZstdDecompressor().decompress(raw, max_output_size=size)
                   if raw[:4] == b"\x28\xb5\x2f\xfd" else
                   lz4.block.decompress(raw, uncompressed_size=size))
        if len(raw) != size:
            raise ValueError("Invalid chunk size")
        items.append((tag, raw, data[start:position]))
        if tag == b"END\x00":
            break
    return data[:32], items


def pack(source, destination, source_root):
    header, chunks = decode(source)
    classes, objects, properties = {}, {}, []
    children, parents = [], []
    for tag, raw, _ in chunks:
        reader = Reader(raw)
        if tag == b"INST":
            cid, name, service, count = reader.uint(), reader.string().decode(), reader.take(1), reader.uint()
            ids = reader.refs(count)
            classes[cid] = (name, ids)
            for iid in ids:
                objects[iid] = {"class": name}
        elif tag == b"PROP":
            cid, name, kind = reader.uint(), reader.string().decode(), reader.take(1)
            properties.append((cid, name, kind, raw, reader.position))
        elif tag == b"PRNT":
            reader.take(1)
            count = reader.uint()
            children, parents = reader.refs(count), reader.refs(count)
    for cid, name, kind, raw, offset in properties:
        if name == "Name":
            reader = Reader(raw[offset:])
            for iid in classes[cid][1]:
                objects[iid]["name"] = reader.string().decode()
    for iid, parent in zip(children, parents):
        objects[iid]["parent"] = parent

    def object_path(iid):
        obj = objects[iid]
        return ((object_path(obj["parent"]) + "/") if obj["parent"] != -1 else "") + obj["name"]

    by_path = {object_path(iid): iid for iid in objects}
    sources = {}
    for path in pathlib.Path(source_root).rglob("*.luau"):
        relative = path.relative_to(source_root).as_posix()
        for suffix in (".server.luau", ".client.luau", ".luau"):
            if relative.endswith(suffix):
                relative = relative[:-len(suffix)]
                break
        sources[relative] = path.read_bytes()
    obsolete = by_path.get("ReplicatedStorage/HookmanJudge")
    replacements = {}
    for cid, name, kind, raw, offset in properties:
        if name == "Source":
            assert kind == b"\x01"
            reader = Reader(raw[offset:])
            values = []
            for iid in classes[cid][1]:
                original = reader.string()
                values.append(sources.get(object_path(iid), original))
            replacements[(cid, name)] = raw[:offset] + b"".join(string(v) for v in values)
    additions = []
    next_id = max(objects) + 1
    for path in sorted(sources.keys() - by_path.keys()):
        parent_path, name = path.rsplit("/", 1)
        if parent_path not in by_path:
            raise ValueError("New script parent not found: " + parent_path)
        additions.append((next_id, name, by_path[parent_path], sources[path]))
        next_id += 1
    new_cid = max(classes) + 1
    result = []
    event_cid = next(cid for cid, (_, ids) in classes.items() if obsolete in ids) if obsolete is not None else None
    for tag, raw, original in chunks:
        reader = Reader(raw)
        if tag == b"INST" and reader.uint() == event_cid:
            name, ids = classes[event_cid]
            kept = [i for i in ids if i != obsolete]
            result.append(chunk(tag, uint(event_cid) + string(name) + b"\x00" + uint(len(kept)) + refs(kept)))
        elif tag == b"PROP":
            cid, name = reader.uint(), reader.string().decode()
            if cid == event_cid:
                if name == "Name":
                    kept = [i for i in classes[cid][1] if i != obsolete]
                    result.append(chunk(tag, uint(cid) + string("Name") + b"\x01" + b"".join(string(objects[i]["name"]) for i in kept)))
                # Removed event's group metadata is default-valued; regenerate surviving event metadata in Studio.
                continue
            value = replacements.get((cid, name))
            result.append(chunk(tag, value) if value is not None and value != raw else original)
        elif tag == b"PRNT":
            if additions:
                result.append(chunk(b"INST", uint(new_cid) + string("ModuleScript") + b"\x00" + uint(len(additions)) + refs([a[0] for a in additions])))
                for property_name, values in (("Name", [a[1] for a in additions]), ("Source", [a[3] for a in additions])):
                    result.append(chunk(b"PROP", uint(new_cid) + string(property_name) + b"\x01" + b"".join(string(v) for v in values)))
            pairs = [(i, p) for i, p in zip(children, parents) if i != obsolete]
            pairs += [(a[0], a[2]) for a in additions]
            result.append(chunk(tag, b"\x00" + uint(len(pairs)) + refs([p[0] for p in pairs]) + refs([p[1] for p in pairs])))
        else:
            result.append(original)
    new_header = bytearray(header)
    struct.pack_into("<II", new_header, 16, len(classes) + bool(additions), len(objects) - (obsolete is not None) + len(additions))
    payload = bytes(new_header) + b"".join(result)
    target = pathlib.Path(destination)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_bytes(payload)
    temporary.replace(target)
    print(f"Packed {len(sources)} scripts ({len(additions)} added); {len(payload)} bytes; sha256={hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="backups/Hookman.original.rbxl")
    parser.add_argument("--output", default="Hookman.rbxl")
    parser.add_argument("--scripts", default="src")
    args = parser.parse_args()
    pack(args.source, args.output, args.scripts)
