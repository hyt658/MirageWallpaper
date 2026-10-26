#!/usr/bin/env python3
# Mirage Wallpaper
# Copyright © 2026 王孝慈. All rights reserved.

"""Version-locked 2.8.42 GPU preview, titlebar input and particle compatibility patch."""

import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ORIGINAL_SHA256 = "dab38bfc017dd5fd4947a09706d23f27833870d1bbb87485677a3e67d1d55791"


def patch(original):
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA256:
        raise ValueError("Unsupported Wallpaper Engine executable / 不支持的 Wallpaper Engine 版本")
    data = bytearray(original)
    pe = struct.unpack_from("<I", data, 60)[0]
    opt = pe + 24
    count = struct.unpack_from("<H", data, pe + 6)[0]
    section_table = opt + struct.unpack_from("<H", data, pe + 20)[0]
    sections = [struct.unpack_from("<8sIIII", data, section_table + i * 40) for i in range(count)]

    def offset(rva):
        for _, _, va, raw_size, raw_offset in sections:
            if va <= rva < va + raw_size:
                return raw_offset + rva - va
        raise ValueError(hex(rva))

    edits = []

    def edit(rva, before, after, purpose):
        start = offset(rva)
        assert len(before) == len(after) and data[start:start + len(before)] == before
        data[start:start + len(before)] = after
        edits.append(dict(rva=hex(rva), before=before.hex(), after=after.hex(), purpose=purpose))

    edit(0xadec88, b"use", b"wpx", "Allow caller-selected CEF graphics backend")
    # Windows blobs embed GS_ENABLED and the matching particle input layout.
    # Their cache key does not include that capability. Keep the original
    # project's Windows cache intact and compile a separate compatible cache.
    edit(0xab2b80, b"blobsSM40", b"blobsMG40", "Keep editor shader cleanup in the Mac cache namespace")
    edit(0xae9d38, b"blobsSM40", b"blobsMG40", "Separate Mac particle shaders from Windows shader blobs")

    align = lambda value, alignment: (value + alignment - 1) & ~(alignment - 1)
    section_alignment, file_alignment = struct.unpack_from("<II", data, opt + 32)
    code_rva = align(max(s[2] + max(s[1], s[3]) for s in sections), section_alignment)
    code_offset = align(len(data), file_alignment)
    # Keep the scene child associated with CEF's render window. Its swapchain
    # is hidden by NativeCompositor; pixels are imported into CEF with Metal.
    code = bytearray.fromhex("4883ec5848894c242048895424284c894424304c894c24384889d131d2")
    string_refs = []
    def find_child(class_name):
        code.extend(bytes.fromhex("4c8d05"))
        string_refs.append((len(code), class_name))
        code.extend(b"\0" * 4)
        code.extend(bytes.fromhex("4531c9ff15"))
        code.extend(struct.pack("<i", 0x9e2c30 - (code_rva + len(code) + 4)))
    find_child("Chrome_WidgetWin_1")
    code.extend(bytes.fromhex("4885c07400"))
    missing_widget = len(code) - 1
    code.extend(bytes.fromhex("48894424284889c131d2"))
    find_child("Chrome_RenderWidgetHostHWND")
    code.extend(bytes.fromhex("4885c074054889442428"))
    code[missing_widget] = len(code) - missing_widget - 1
    code.extend(bytes.fromhex("488b4c2420488b5424284c8b4424304c8b4c24384883c458488951104533e4c3"))
    for reference, name in string_refs:
        struct.pack_into("<i", code, reference, len(code) - reference - 4)
        code.extend(name.encode("utf-16le") + b"\0\0")
    hook = 0x11b9c2
    before = bytes(data[offset(hook):offset(hook) + 7])
    assert before == bytes.fromhex("488951104533e4")
    # The stock non-client hit test reserves the entire left titlebar for
    # HTCAPTION, swallowing clicks before CEF sees the relocated controls.
    # At this return site x/y have already been converted to 96-DPI logical
    # client coordinates. Only change caption hits inside the traffic lights.
    traffic_rva = code_rva + len(code)
    traffic = bytearray.fromhex("488b459f83f8027500")
    exits = [8]
    for instruction in ("837c24400a7c00", "837c2440507d00",
                        "837c2444087c00", "837c2444207d00"):
        traffic.extend(bytes.fromhex(instruction))
        exits.append(len(traffic) - 1)
    traffic.extend(bytes.fromhex("b801000000"))  # HTCLIENT
    for branch in exits:
        traffic[branch] = len(traffic) - branch - 1
    traffic.extend(b"\xe9" + struct.pack("<i", 0x136916 - (traffic_rva + len(traffic) + 5)))
    code.extend(traffic)
    edit(0x136824, bytes.fromhex("488b459fe9e9000000"),
         b"\xe9" + struct.pack("<i", traffic_rva - 0x136829) + b"\x90" * 4,
         "Route left titlebar control clicks to CEF while retaining caption drag and edge resize")
    # Renderer construction copies the scene capabilities from options+0x20.
    # Bit 3 enables geometry shaders (also read by the GS_ENABLED preamble).
    # MoltenVK cannot execute that stage. Clear it before particle buffers and
    # shaders are created so the engine uses its existing expanded-quad path.
    particle_rva = code_rva + len(code)
    particle = bytearray.fromhex("8b422083e0f7898118010000")
    particle.extend(b"\xe9" + struct.pack("<i", 0x453a3c - (particle_rva + len(particle) + 5)))
    code.extend(particle)
    edit(0x453a33, bytes.fromhex("8b4220898118010000"),
         b"\xe9" + struct.pack("<i", particle_rva - 0x453a38) + b"\x90" * 4,
         "Use the engine's vertex-shader particle path on MoltenVK")
    particle_update_rva = code_rva + len(code)
    particle_update = bytearray.fromhex("83e0f7898728010000")
    particle_update.extend(b"\xe9" + struct.pack("<i", 0x4e75fd - (particle_update_rva + len(particle_update) + 5)))
    code.extend(particle_update)
    edit(0x4e75f7, bytes.fromhex("898728010000"),
         b"\xe9" + struct.pack("<i", particle_update_rva - 0x4e75fc) + b"\x90",
         "Keep geometry shaders disabled when scene flags are updated")
    header = section_table + count * 40
    assert header + 40 <= min(s[4] for s in sections)
    assert not any(data[header:header + 40])
    raw_size = align(len(code), file_alignment)
    data[header:header + 40] = struct.pack("<8sIIIIIIHHI", b".mirage\0", len(code), code_rva,
                                         raw_size, code_offset, 0, 0, 0, 0, 0x60000020)
    struct.pack_into("<H", data, pe + 6, count + 1)
    struct.pack_into("<I", data, opt + 56, align(code_rva + len(code), section_alignment))
    struct.pack_into("<I", data, opt + 64, 0)  # Invalidate the original PE checksum.
    data.extend(b"\0" * (code_offset - len(data)))
    data.extend(code)
    data.extend(b"\0" * (raw_size - len(code)))
    manifest = dict(_copyright="Copyright © 2026 王孝慈. All rights reserved.",
                    original_sha256=ORIGINAL_SHA256, sha256=hashlib.sha256(data).hexdigest(),
                    patches=edits, section_rva=hex(code_rva), section_code=code.hex())
    return data, manifest


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    args = parser.parse_args()
    ROOT = args.runtime.resolve()
    executable, manifest = patch((ROOT / "originals/wallpaperui.exe").read_bytes())
    (ROOT / "windows/WallpaperEngine/bin/wallpaperui.exe").write_bytes(executable)
    (ROOT / "native-preview-patch.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
