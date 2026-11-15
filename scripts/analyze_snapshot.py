#!/usr/bin/env python3
"""Read-only v2 container analysis. Candidate columns are evidence, never write authorization."""
from pathlib import Path
import argparse
import hashlib
import json
import struct

class Store:
    def __init__(self, data):
        self.data = data
        if not 100 <= len(data) <= 64 * 1024 * 1024 or data[:5] != b"bdsl\x02":
            raise ValueError("Not a bounded v2 CoreServicesStore")
        if not self.u32(20) & 0x40000000: raise ValueError("Missing catalog marker")
        self.tables = {}
        for _, (offset, size) in self.table(20).items():
            name = self.text(offset, min(48, size))
            if not name or name in self.tables: raise ValueError("Ambiguous catalog")
            self.tables[name] = self.table(offset)
        if not {"Bundle", "<string>"} <= self.tables.keys(): raise ValueError("Missing tables")
    def bounds(self, offset, size):
        if offset < 0 or size < 0 or offset > len(self.data) or size > len(self.data) - offset:
            raise ValueError(f"Out-of-bounds reference at {offset:#x}")
    def u32(self, offset):
        self.bounds(offset, 4); return struct.unpack_from("<I", self.data, offset)[0]
    def table(self, descriptor):
        self.bounds(descriptor, 80)
        size = self.u32(descriptor + 4)
        if size < 72: raise ValueError("Truncated table")
        self.bounds(descriptor + 8, size)
        table = self.u32(descriptor + 76)
        if table < 100: raise ValueError("Invalid hash pointer")
        buckets = self.u32(table)
        if buckets > 1000000: raise ValueError("Excessive bucket count")
        self.bounds(table + 4, buckets * 8)
        result = {}; total = 0
        for bucket in range(buckets):
            count = self.u32(table + 4 + bucket * 8)
            if not count: continue
            total += count
            if total > 1000000: raise ValueError("Excessive entry count")
            start = self.u32(table + 8 + bucket * 8)
            if start < 100: raise ValueError("Invalid bucket pointer")
            self.bounds(start, count * 8)
            for index in range(count):
                key, offset = struct.unpack_from("<II", self.data, start + index * 8)
                if offset == 0xffffffff: continue
                if offset < 100: raise ValueError("Unit overlaps header")
                size = self.u32(offset + 4); self.bounds(offset + 8, size)
                if key in result: raise ValueError("Duplicate unit key")
                result[key] = (offset, size)
        return result
    def text(self, unit, size):
        self.bounds(unit + 8, size)
        return self.data[unit + 8:unit + 8 + size].split(b"\0", 1)[0].decode("utf-8")
    def report(self, catalog=None):
        sizes = {}
        for _, size in self.tables["Bundle"].values(): sizes[str(size)] = sizes.get(str(size), 0) + 1
        result = {"bytes": len(self.data), "sha256": hashlib.sha256(self.data).hexdigest(),
            "tables": {name: len(units) for name, units in self.tables.items()}, "bundleRecordSizes": sizes,
            "compatibilityKeyStringOccurrences": self.data.count(b"UIDesignRequiresCompatibility"),
            "liveWriteAuthorized": False,
            "warning": "A matching byte pattern or string does not prove a field's semantics or appearance behavior."}
        if catalog:
            strings = {}
            for key, (offset, size) in self.tables["<string>"].items():
                if size <= 4096:
                    try: strings.setdefault(self.text(offset, size), set()).add(key)
                    except UnicodeDecodeError: pass
            observations = []
            for app in catalog.get("applications", []):
                sdk = app.get("reportedSDK")
                if not sdk: continue
                triple = struct.pack("<QQQ", sdk["major"], sdk["minor"], sdk["patch"])
                keys = strings.get(app["bundleID"], set())
                for record_key, (unit, size) in self.tables["Bundle"].items():
                    if size > 4096: continue
                    body = unit + 8
                    identity = [i for i in range(0, size - 3, 4) if self.u32(body + i) in keys]
                    if len(identity) < 2: continue
                    candidates = [i for i in range(0, size - 23, 4) if self.data[body + i:body + i + 24] == triple]
                    observations.append({"bundleID": app["bundleID"], "recordKey": record_key, "recordSize": size,
                        "recordBody": body, "candidateIdentityOffsets": identity, "candidateSDKOffsets": candidates})
            result["readOnlyObservations"] = observations
        return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--catalog", type=Path, help="ForceLegacyUI diagnostic report.json")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.snapshot.stat().st_size > 64 * 1024 * 1024: raise SystemExit("Snapshot exceeds 64 MiB")
    store = Store(args.snapshot.read_bytes())
    catalog = json.loads(args.catalog.read_text()) if args.catalog else None
    output = json.dumps(store.report(catalog), indent=2, sort_keys=True) + "\n"
    if args.output: args.output.write_text(output, encoding="utf-8")
    else: print(output, end="")

if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, KeyError, struct.error) as error: raise SystemExit(str(error)) from None
