#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import pathlib
import tarfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a legacy OpenWrt ipk using a gzip-wrapped tar container.")
    parser.add_argument("--stage-dir", required=True, help="Directory containing package payload files.")
    parser.add_argument("--control-dir", required=True, help="Directory containing control files.")
    parser.add_argument("--output", required=True, help="Output ipk path.")
    parser.add_argument(
        "--source-date-epoch",
        type=int,
        default=1773321366,
        help="Fixed timestamp used for tar and gzip member metadata.",
    )
    return parser.parse_args()


def tar_info_for_path(root: pathlib.Path, path: pathlib.Path, mtime: int) -> tarfile.TarInfo:
    relative = path.relative_to(root)
    if str(relative) == ".":
        name = "."
    else:
        name = "./" + relative.as_posix()

    stat_result = path.stat()
    info = tarfile.TarInfo(name)
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = mtime
    info.mode = stat_result.st_mode & 0o7777
    if path.is_dir():
        info.type = tarfile.DIRTYPE
        info.size = 0
    else:
        info.type = tarfile.REGTYPE
        info.size = stat_result.st_size
    return info


def build_inner_archive(root: pathlib.Path, mtime: int) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buffer, mtime=mtime) as gz_file:
        with tarfile.open(fileobj=gz_file, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            paths = [root]
            paths.extend(sorted(root.rglob("*"), key=lambda item: item.as_posix()))
            for path in paths:
                info = tar_info_for_path(root, path, mtime)
                if path.is_dir():
                    archive.addfile(info)
                else:
                    with path.open("rb") as handle:
                        archive.addfile(info, handle)
    return buffer.getvalue()


def build_outer_archive(control_bytes: bytes, data_bytes: bytes, output: pathlib.Path, mtime: int) -> bytes:
    entries = [
        ("./debian-binary", b"2.0\n"),
        ("./data.tar.gz", data_bytes),
        ("./control.tar.gz", control_bytes),
    ]

    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buffer, mtime=mtime) as gz_file:
        with tarfile.open(fileobj=gz_file, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, payload in entries:
                info = tarfile.TarInfo(name)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                info.mtime = mtime
                info.mode = 0o644
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))

    output_bytes = buffer.getvalue()
    output.write_bytes(output_bytes)
    return output_bytes


def main() -> int:
    args = parse_args()
    stage_dir = pathlib.Path(args.stage_dir).resolve()
    control_dir = pathlib.Path(args.control_dir).resolve()
    output_path = pathlib.Path(args.output).resolve()

    output_path.parent.mkdir(parents=True, exist_ok=True)

    control_bytes = build_inner_archive(control_dir, args.source_date_epoch)
    data_bytes = build_inner_archive(stage_dir, args.source_date_epoch)
    output_bytes = build_outer_archive(control_bytes, data_bytes, output_path, args.source_date_epoch)

    sha256_path = output_path.with_suffix(output_path.suffix + ".sha256")
    sha256_path.write_text(
        f"{hashlib.sha256(output_bytes).hexdigest()}  {output_path.name}\n",
        encoding="ascii",
    )

    print(output_path)
    print(sha256_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
