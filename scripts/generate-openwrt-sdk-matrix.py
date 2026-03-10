#!/usr/bin/env python3
import argparse
import concurrent.futures
import gzip
import json
import re
import time
import sys
import urllib.request
from html import unescape
from urllib.parse import urljoin


DIR_LINK_RE = re.compile(r'href="([^"]+/)"')
PKGARCH_RE = re.compile(r'^Architecture: ([^\s]+)$', re.MULTILINE)


def fetch_bytes(url: str) -> bytes:
    last_error = None
    for attempt in range(4):
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": "jludrcom-build-matrix/1.0",
                "Connection": "close",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.read()
        except Exception as exc:
            last_error = exc
            if attempt == 3:
                break
            time.sleep(0.5 * (attempt + 1))
    raise last_error


def fetch_text(url: str) -> str:
    return fetch_bytes(url).decode("utf-8", errors="replace")


def list_directories(url: str) -> list[str]:
    html = fetch_text(url)
    items = []
    for href in DIR_LINK_RE.findall(html):
        if href.startswith("/") or href.startswith("?") or href.startswith("../"):
            continue
        name = unescape(href).strip("/")
        if not name or name == ".." or "/" in name:
            continue
        if name not in items:
            items.append(name)
    return sorted(items)


def sdk_entry_for_target(release: str, target: str, subtarget: str) -> dict | None:
    base_url = f"https://downloads.openwrt.org/releases/{release}/targets/{target}/{subtarget}/"
    packages_urls = (
        urljoin(base_url, "packages/Packages.gz"),
        urljoin(base_url, "packages/Packages"),
    )

    try:
        pkg_index = gzip.decompress(fetch_bytes(packages_urls[0])).decode("utf-8", errors="replace")
    except Exception:
        try:
            pkg_index = fetch_text(packages_urls[1])
        except Exception:
            return None

    pkgarch_match = PKGARCH_RE.search(pkg_index)
    if not pkgarch_match:
        return None

    pkgarch = pkgarch_match.group(1).strip()
    return {
        "target": target,
        "subtarget": subtarget,
        "pkgarch": pkgarch,
    }


def generate_matrix(release: str, workers: int) -> list[dict]:
    targets_url = f"https://downloads.openwrt.org/releases/{release}/targets/"
    candidates: list[tuple[str, str]] = []
    entries: list[dict] = []

    for target in list_directories(targets_url):
        target_url = urljoin(targets_url, f"{target}/")
        for subtarget in list_directories(target_url):
            candidates.append((target, subtarget))

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        futures = {
            executor.submit(sdk_entry_for_target, release, target, subtarget): (target, subtarget)
            for target, subtarget in candidates
        }
        for future in concurrent.futures.as_completed(futures):
            entry = future.result()
            if entry is None:
                continue
            entries.append(entry)

    entries.sort(key=lambda item: (item["pkgarch"], item["target"], item["subtarget"]))
    matrix_by_pkgarch: dict[str, dict] = {}
    for entry in entries:
        matrix_by_pkgarch.setdefault(entry["pkgarch"], entry)

    if not matrix_by_pkgarch:
        raise RuntimeError(f"No SDK targets discovered for OpenWrt {release}")

    return [matrix_by_pkgarch[key] for key in sorted(matrix_by_pkgarch)]


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a de-duplicated OpenWrt SDK build matrix by pkgarch.")
    parser.add_argument("--release", required=True, help="OpenWrt release, for example 24.10.5")
    parser.add_argument("--workers", type=int, default=16, help="Concurrent target fetch workers")
    args = parser.parse_args()

    try:
        matrix = generate_matrix(args.release, args.workers)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1

    json.dump(matrix, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
