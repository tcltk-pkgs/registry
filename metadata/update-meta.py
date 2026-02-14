#!/usr/bin/env python3

import json
import subprocess
import tempfile
import os
import re
import sys
import random
import shutil
from datetime import datetime, timezone
from pathlib import Path

INPUT_FILE = "packages.json"
OUTPUT_FILE = "metadata/packages-meta.json"


def run_cmd(cmd, cwd=None, timeout=15):
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
        if result.returncode == 0:
            return result.stdout.strip()
        # BUG FIX #1: log the actual error instead of silently returning None
        if result.stderr.strip():
            print(f"    [cmd stderr] {result.stderr.strip()[:120]}", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        print(f"    [timeout] {cmd[:80]}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"    [run_cmd error] {e}", file=sys.stderr)
        return None


def run_curl(url, timeout=20):
    """
    Run curl and return (body, http_code).
    BUG FIX #2: curl -s exits 0 even on HTTP 4xx/5xx.
    We capture the HTTP status separately to detect real failures.
    """
    cmd = f'curl -s -L --max-time {timeout} -w "\\n__HTTP_CODE__%{{http_code}}" "{url}"'
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout + 5
        )
        output = result.stdout
        # Split body from the status code trailer
        if "__HTTP_CODE__" in output:
            body, code_str = output.rsplit("__HTTP_CODE__", 1)
            http_code = int(code_str.strip()) if code_str.strip().isdigit() else 0
        else:
            body = output
            http_code = 0
        body = body.strip()
        return body, http_code
    except subprocess.TimeoutExpired:
        print(f"    [curl timeout] {url[:80]}", file=sys.stderr)
        return None, 0
    except Exception as e:
        print(f"    [curl error] {e}", file=sys.stderr)
        return None, 0


def extract_fossil_base(url):
    """
    Extract the Fossil repo root URL from any Fossil URL.

    Examples:
      https://core.tcl-lang.org/tcllib/dir?name=modules/ftp&ci=trunk
        -> https://core.tcl-lang.org/tcllib
      https://chiselapp.com/user/rkeene/repository/tcllib/index
        -> https://chiselapp.com/user/rkeene/repository/tcllib
    """
    # BUG FIX #3: the old regex ^(https?://[^/]+/[^/]+) only keeps ONE path segment.
    # That's correct for core.tcl-lang.org/tcllib but wrong for multi-segment repos.
    # Strategy: strip known Fossil page suffixes to find the repo root.
    FOSSIL_PAGES = (
        '/dir', '/file', '/doc', '/wiki', '/ticket', '/timeline',
        '/info', '/artifact', '/raw', '/zip', '/tarball', '/json',
        '/index', '/home',
    )
    # Normalize: remove query string and trailing slash first
    base = url.split('?')[0].rstrip('/')
    # Strip known page paths iteratively
    for page in FOSSIL_PAGES:
        if page in base:
            base = base[:base.index(page)]
            break
    return base.rstrip('/')


def process_git(url, temp_base):
    tmpdir = os.path.join(
        temp_base,
        f"git-{int(datetime.now().timestamp())}-{random.randint(0, 9999)}"
    )

    meta = {
        "last_commit": None,
        "last_commit_sha": None,
        "last_tag": None,
    }

    try:
        result = run_cmd(
            f'git clone --depth 1 --filter=blob:none --no-checkout "{url}" "{tmpdir}"',
            timeout=30
        )
        if result is None and not os.path.isdir(tmpdir):
            print(f"    [git] clone failed: {url}", file=sys.stderr)
            meta["error"] = "clone_failed"
            return meta

        commit_date = run_cmd('git log -1 --format=%ci', cwd=tmpdir)
        if commit_date:
            meta["last_commit"] = commit_date

        commit_sha = run_cmd('git rev-parse --short HEAD', cwd=tmpdir)
        if commit_sha:
            meta["last_commit_sha"] = commit_sha

        tags_output = run_cmd('git tag --sort=-creatordate', cwd=tmpdir)
        if tags_output:
            tags = [t.strip() for t in tags_output.split('\n') if t.strip()]
            if tags:
                meta["last_tag"] = tags[0]

    except Exception as e:
        print(f"    [git error] {e}", file=sys.stderr)
        meta["error"] = str(e)
    finally:
        if os.path.exists(tmpdir):
            shutil.rmtree(tmpdir, ignore_errors=True)

    return meta


def parse_fossil_date_from_html(html):
    """
    Extract the most recent commit date and SHA from a Fossil /timeline HTML page.

    Fossil does NOT use HTML5 datetime= attributes. It embeds dates in several ways
    depending on the version and skin. We try them all, most specific first.
    """
    date = None
    sha = None

    # --- Date extraction (try patterns in order of specificity) ---

    # Pattern A: <span class='timelineHistDsp'>2024-01-15 14:23:07</span>
    # Used by most Fossil skins including the default one on core.tcl-lang.org
    if m := re.search(
        r"timelineHistDsp[^>]*>\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})",
        html
    ):
        date = m.group(1)

    # Pattern B: <td class="timelineDateCell">2024-01-15</td> (date-only cell)
    # Combined with nearby time. Less precise but better than nothing.
    if not date:
        if m := re.search(
            r'timelineDateCell[^>]*>\s*<[^>]*>\s*(\d{4}-\d{2}-\d{2})',
            html
        ):
            date = m.group(1)

    # Pattern C: Generic ISO datetime anywhere in the page (last resort)
    # Matches "2024-01-15 14:23:07" or "2024-01-15T14:23:07"
    if not date:
        if m := re.search(r'(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})', html):
            date = m.group(1)

    # --- SHA extraction ---
    # Fossil timeline links: href="/repo/info/a1b2c3d4e5f6" or ?c=a1b2c3d4e5
    if m := re.search(r'/info/([0-9a-f]{10,40})', html):
        sha = m.group(1)[:10]
    elif m := re.search(r'[?&]c=([0-9a-f]{10,40})', html):
        sha = m.group(1)[:10]

    return date, sha


def _pick_version_tag(html):
    """
    Extract the most recent version tag from a Fossil /taglist or /brlist HTML page.
    Skips pseudo-tags like 'trunk', 'branch-*', 'tip', etc.
    Returns the first tag containing a digit, or None.
    """
    SKIP = re.compile(r'^(trunk|tip|release|branch|main|HEAD)$', re.IGNORECASE)
    # /taglist: href="...?t=tcllib-1-21-0"  /brlist: href="...?r=tcllib-1-21-0"
    candidates = re.findall(r"timeline\?[tr]=([^\"'&>\s]+)", html)
    for tag in candidates:
        tag = tag.strip()
        if SKIP.match(tag):
            continue
        if re.search(r'\d', tag):  # version tags contain at least one digit
            return tag
    return None


# Cache for Fossil repos: base_url -> meta dict
# BUG FIX #4: many packages share the same repo (e.g. all of tcllib).
# Without a cache, the same URL gets fetched once per package -> infinite-looking loop.
_fossil_cache: dict = {}


def process_fossil(url, temp_base):
    base = extract_fossil_base(url)
    print(f"    [fossil] base URL: {base}")

    # Return cached result immediately if we already fetched this repo
    if base in _fossil_cache:
        print(f"    [fossil] cache hit")
        return dict(_fossil_cache[base])  # return a copy

    meta = {
        "last_commit": None,
        "last_commit_sha": None,
        "last_tag": None,
    }

    # --- 1. Try JSON API ---
    # Note: core.tcl-lang.org returns HTTP 404 for /json/timeline (API disabled).
    # We detect this and skip straight to HTML instead of logging a noisy error.
    timeline_url = f"{base}/json/timeline?type=ci&limit=1"
    print(f"    [fossil] trying API: {timeline_url}")

    body, http_code = run_curl(timeline_url, timeout=20)

    if body and http_code == 200:
        try:
            data = json.loads(body)
            # Fossil JSON API v2 wraps results in 'payload'
            timeline = data.get('payload', {}).get('timeline') or data.get('timeline', [])
            if timeline:
                entry = timeline[0]
                meta["last_commit"] = entry.get('timestamp') or entry.get('mtime')
                sha = entry.get('uuid') or entry.get('hash')
                if sha:
                    meta["last_commit_sha"] = sha[:10]
                print(f"    [fossil] API OK: commit={meta['last_commit']}")
        except json.JSONDecodeError as e:
            print(f"    [fossil] JSON parse error: {e}", file=sys.stderr)
    elif http_code == 404:
        # JSON API not enabled on this server — go straight to HTML, no noise
        print(f"    [fossil] JSON API not available (404), using HTML")
    else:
        print(
            f"    [fossil] API failed (http={http_code}, body_len={len(body) if body else 0})",
            file=sys.stderr
        )

    # --- 2. HTML fallback ---
    if not meta["last_commit"]:
        print(f"    [fossil] fetching HTML timeline")
        html, http_code = run_curl(f"{base}/timeline", timeout=20)
        if html and http_code == 200:
            date, sha = parse_fossil_date_from_html(html)
            if date:
                meta["last_commit"] = date
                if sha and not meta["last_commit_sha"]:
                    meta["last_commit_sha"] = sha
                print(f"    [fossil] HTML OK: commit={meta['last_commit']}")
            else:
                # Dump a snippet to help debug future regex failures
                snippet = re.sub(r'\s+', ' ', html[:300])
                print(
                    f"    [fossil] HTML: no date in {len(html)} bytes. Snippet: {snippet}",
                    file=sys.stderr
                )
                meta["error"] = "date_not_found"
        else:
            print(
                f"    [fossil] HTML also failed (http={http_code})",
                file=sys.stderr
            )
            meta["error"] = f"http_{http_code}"

    # --- 3. Tags ---
    # JSON API first, then HTML /taglist, then /brlist (core.tcl-lang.org has 404 on JSON)
    tag = None

    tags_body, tags_code = run_curl(f"{base}/json/taglist", timeout=15)
    if tags_body and tags_code == 200:
        try:
            data = json.loads(tags_body)
            raw_tags = data.get('payload', {}).get('tags') or data.get('tags', [])
            if raw_tags:
                tag = raw_tags[0].get('name') or raw_tags[0].get('tagname')
        except json.JSONDecodeError:
            pass

    if not tag:
        for endpoint in (f"{base}/taglist", f"{base}/brlist"):
            body, code = run_curl(endpoint, timeout=15)
            if body and code == 200:
                tag = _pick_version_tag(body)
                if tag:
                    break

    if tag:
        meta["last_tag"] = tag
        print(f"    [fossil] tag: {tag}")

    # Store in cache so sibling packages skip the network round-trip
    _fossil_cache[base] = meta
    return dict(meta)


def main():
    print(f"Generating {OUTPUT_FILE}...")

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)

    with open(INPUT_FILE, 'r', encoding='utf-8') as f:
        packages = json.load(f)

    total = len(packages)
    print(f"{total} packages to process")

    enriched_packages = []

    with tempfile.TemporaryDirectory(prefix='registry-meta-') as temp_base:
        for idx, package in enumerate(packages, 1):
            name = package['name']
            print(f"[{idx}/{total}] {name}")

            enriched_sources = []

            for source in package.get('sources', []):
                method = source.get('method', '')
                url = source.get('url', '')
                print(f"  -> {method}: {url[:70]}...")

                if method == 'git':
                    meta = process_git(url, temp_base)
                elif method == 'fossil':
                    meta = process_fossil(url, temp_base)
                else:
                    meta = {
                        "last_commit": None,
                        "last_commit_sha": None,
                        "last_tag": None,
                        "error": "unknown_method",
                    }

                enriched_source = {**source, **meta}
                enriched_sources.append(enriched_source)

            new_package = {
                "name": package['name'],
                "sources": enriched_sources,
                "tags": package.get('tags', []),
                "description": package.get('description', ''),
            }
            enriched_packages.append(new_package)

    meta_header = {
        "packages": "Tcl/Tk",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    final_output = [meta_header] + enriched_packages

    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, separators=(',', ':'), ensure_ascii=False)

    file_size = os.path.getsize(OUTPUT_FILE)
    print(f"File generated: {OUTPUT_FILE} ({file_size} bytes)")


if __name__ == "__main__":
    main()
