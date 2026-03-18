#!/usr/bin/env python3
import argparse
import os
import pathlib
import re
import sys


KEEP_SECTIONS = {"[Interface]", "[Peer]"}
DROP_INTERFACE_KEYS = {"dns", "table", "preup", "postup", "predown", "postdown", "saveconfig"}


def compact_blank(lines):
    out = []
    prev_blank = False
    for line in lines:
        blank = not line.strip()
        if blank and prev_blank:
            continue
        out.append("" if blank else line.rstrip())
        prev_blank = blank
    while out and not out[-1].strip():
        out.pop()
    return out


def render_wgquick(source_text):
    out = []
    current = None
    table_inserted = False

    for raw in source_text.splitlines():
        line = raw.rstrip("\n")
        stripped = line.strip()

        if stripped.startswith("[") and stripped.endswith("]"):
            if current == "[Interface]" and not table_inserted:
                out.append("Table = off")
                out.append("")
                table_inserted = True
            current = stripped if stripped in KEEP_SECTIONS else None
            if current is not None:
                out.append(current)
            continue

        if current is None:
            continue

        if not stripped:
            out.append("")
            continue

        if stripped.startswith("#") or stripped.startswith(";"):
            out.append(line)
            continue

        key = stripped.split("=", 1)[0].strip().lower()
        if current == "[Interface]" and key in DROP_INTERFACE_KEYS:
            continue

        out.append(line)

    if current == "[Interface]" and not table_inserted:
        out.append("Table = off")

    rendered = "\n".join(compact_blank(out)).rstrip() + "\n"
    if "[Interface]" not in rendered or "[Peer]" not in rendered:
        raise ValueError("source config does not contain [Interface] and [Peer] sections")
    return rendered


def main():
    parser = argparse.ArgumentParser(description="Render SSH WARP wg-quick config from wireproxy config")
    parser.add_argument("--interface", required=True, help="Target interface name, e.g. warp-ssh0")
    parser.add_argument("--source", default="/etc/wireproxy/config.conf", help="Source wireproxy config")
    parser.add_argument("--dest-dir", default="/etc/wireguard", help="Destination config directory")
    args = parser.parse_args()

    iface = str(args.interface or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,15}", iface):
        raise SystemExit("invalid interface name")

    src = pathlib.Path(args.source)
    if not src.is_file():
        raise SystemExit(f"source config not found: {src}")

    dest_dir = pathlib.Path(args.dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(dest_dir, 0o700)
    except Exception:
        pass

    rendered = render_wgquick(src.read_text(encoding="utf-8"))
    dest = dest_dir / f"{iface}.conf"
    dest.write_text(rendered, encoding="utf-8")
    try:
        os.chmod(dest, 0o600)
    except Exception:
        pass
    print(dest)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise
