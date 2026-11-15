#!/usr/bin/env python3
"""Bounded reader for XML entitlements in our thin arm64 build output."""
import plistlib
import struct

def read_entitlements(data):
    def bounds(offset, size, limit=None):
        limit = len(data) if limit is None else limit
        if offset < 0 or size < 0 or offset > limit or size > limit - offset:
            raise ValueError("Out-of-bounds Mach-O/signature reference")
    bounds(0, 32)
    if data[:4] != bytes.fromhex("cffaedfe"):
        raise ValueError("Expected this project's thin 64-bit little-endian Mach-O output")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    if count > 4096: raise ValueError("Excessive load-command count")
    bounds(32, command_bytes)
    cursor = 32
    for _ in range(count):
        bounds(cursor, 8, 32 + command_bytes)
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8: raise ValueError("Invalid load-command size")
        bounds(cursor, size, 32 + command_bytes)
        if command == 0x1d:
            if size < 16: raise ValueError("Truncated signature command")
            start, length = struct.unpack_from("<II", data, cursor + 8)
            bounds(start, length)
            if length < 12: raise ValueError("Truncated signature superblob")
            magic, blob_length, slots = struct.unpack_from(">III", data, start)
            if magic != 0xfade0cc0 or blob_length > length or blob_length < 12 or slots > 1024:
                raise ValueError("Unknown signature superblob")
            end = start + blob_length
            bounds(start + 12, slots * 8, end)
            for index in range(slots):
                slot, relative = struct.unpack_from(">II", data, start + 12 + index * 8)
                at = start + relative
                bounds(at, 8, end)
                kind, payload_length = struct.unpack_from(">II", data, at)
                if payload_length < 8: raise ValueError("Invalid signature slot")
                bounds(at, payload_length, end)
                if slot == 5 and kind == 0xfade7171:
                    result = plistlib.loads(data[at + 8:at + payload_length])
                    if not isinstance(result, dict): raise ValueError("Entitlements must be a dictionary")
                    return result
            return {}
        cursor += size
    return {}
