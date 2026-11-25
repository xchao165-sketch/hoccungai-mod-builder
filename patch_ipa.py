import argparse
import copy
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LOAD_PATH = "@executable_path/Frameworks/HOControl.dylib"


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def align8(value):
    return (value + 7) & ~7


def make_load_command(path):
    raw = path.encode("utf-8") + b"\0"
    size = align8(24 + len(raw))
    command = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,
        size,
        24,
        0,
        0x00010000,
        0x00010000,
    )
    command += raw.ljust(size - 24, b"\0")
    return command


def section_offsets(data, ncmds, offset):
    result = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            section = offset + 72
            for _ in range(nsects):
                file_offset = struct.unpack_from("<I", data, section + 48)[0]
                if file_offset:
                    result.append(file_offset)
                section += 80
        offset += cmdsize
    return result


def patch_executable(data):
    if len(data) < 32:
        raise ValueError("executable too small")
    if u32(data, 0) != MH_MAGIC_64:
        raise ValueError("not a 64-bit Mach-O")
    cpu_type = struct.unpack_from("<I", data, 4)[0]
    if cpu_type != CPU_TYPE_ARM64:
        raise ValueError("not arm64")
    ncmds = u32(data, 16)
    sizeofcmds = u32(data, 20)
    command = make_load_command(LOAD_PATH)
    insert_at = 32 + sizeofcmds
    insert_end = insert_at + len(command)
    if insert_end > len(data):
        raise ValueError("load command area overflow")
    if any(data[insert_at:insert_end]):
        raise ValueError("no zero padding for new load command")
    offsets = section_offsets(data, ncmds, 32)
    if offsets and insert_end >= min(offsets):
        raise ValueError("new load command overlaps section data")
    patched = bytearray(data)
    patched[insert_at:insert_end] = command
    struct.pack_into("<I", patched, 16, ncmds + 1)
    struct.pack_into("<I", patched, 20, sizeofcmds + len(command))
    return bytes(patched), len(command)


def find_app_info(archive):
    infos = [name for name in archive.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist")]
    if len(infos) != 1:
        raise ValueError(f"expected one app Info.plist, got {len(infos)}")
    payload_name = infos[0]
    app_dir = payload_name[: -len("/Info.plist")]
    info = plistlib.loads(archive.read(payload_name))
    executable = info.get("CFBundleExecutable")
    if not executable:
        raise ValueError("CFBundleExecutable missing")
    return app_dir, f"{app_dir}/{executable}"


def patch_ipa(input_ipa, dylib_path, output_ipa):
    dylib_data = Path(dylib_path).read_bytes()
    with zipfile.ZipFile(input_ipa, "r") as source:
        app_dir, executable_path = find_app_info(source)
        original = source.read(executable_path)
        patched, command_size = patch_executable(original)
        dylib_entry = f"{app_dir}/Frameworks/HOControl.dylib"
        with zipfile.ZipFile(output_ipa, "w", zipfile.ZIP_DEFLATED) as target:
            for item in source.infolist():
                if item.filename == dylib_entry:
                    continue
                data = patched if item.filename == executable_path else source.read(item.filename)
                target.writestr(copy.copy(item), data)
            entry = zipfile.ZipInfo(dylib_entry, date_time=(2026, 11, 25, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 << 16) | 0x10
            target.writestr(entry, dylib_data)
    print(f"app_dir={app_dir}")
    print(f"executable={executable_path}")
    print(f"dylib={dylib_entry}")
    print(f"load_command_size={command_size}")
    print(f"output={output_ipa}")
    print("unsigned; sign with enterprise certificate before install")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_ipa")
    parser.add_argument("dylib")
    parser.add_argument("output_ipa")
    args = parser.parse_args()
    try:
        patch_ipa(args.input_ipa, args.dylib, args.output_ipa)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
