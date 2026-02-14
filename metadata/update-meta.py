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


# Fossil repos that have a Git mirror.
# Used as fallback to fetch tags when the Fossil tag API is unavailable.
# key   = Fossil base URL (as returned by extract_fossil_base)
# value = Git mirror URL
FOSSIL_GIT_MIRRORS = {
    "https://core.tcl-lang.org/tcllib":  "https://github.com/tcltk/tcllib",
    "https://core.tcl-lang.org/tcl":     "https://github.com/tcltk/tcl",
    "https://core.tcl-lang.org/tk":      "https://github.com/tcltk/tk",
}


def _latest_tag_from_git_mirror(git_url):
    """
    Fetch tags from a Git mirror using ls-remote (no clone needed).
    Returns the most recent version tag, or None on failure.
    """
    output = run_cmd(
        f'git ls-remote --tags --refs "{git_url}"',
        timeout=30
    )
    if not output:
        return None

    tags = []
    for line in output.splitlines():
        if m := re.match(r'[0-9a-f]+\s+refs/tags/(.+)', line.strip()):
            tag = m.group(1).strip()
            if re.search(r'\d', tag):   # skip tags with no digits
                tags.append(tag)

    if not tags:
        return None

    # Sort by numeric components so 1-21-0 > 1-20-1 > 1-9-0
    def version_key(t):
        return [int(n) for n in re.findall(r'\d+', t)]

    return sorted(tags, key=version_key, reverse=True)[0]


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


# Two-level cache for Fossil repos:
#   _fossil_repo_cache : base_url  -> {last_tag}                  (one fetch per repo)
#   _fossil_date_cache : source_url -> {last_commit, last_commit_sha}  (one fetch per module path)
_fossil_repo_cache: dict = {}
_fossil_date_cache: dict = {}



def _extract_module_path(source_url):
    """Extract 'modules/textutil' from a Fossil dir URL like
    https://core.tcl-lang.org/tcllib/dir?name=modules/textutil&ci=trunk
    Returns None if no name param found (= whole-repo URL)."""
    if m := re.search(r'[?&]name=([^&]+)', source_url):
        return m.group(1)
    return None


def _github_api_commit(git_url, module_path):
    """
    Query the GitHub API for the last commit on a specific path.
    Returns (iso_date, sha_short) or (None, None).
    No auth needed for public repos (60 req/h unauthenticated).
    """
    m = re.match(r'https://github\.com/([^/]+/[^/.]+)', git_url)
    if not m:
        return None, None
    repo = m.group(1)
    path = module_path or ""
    api_url = f"https://api.github.com/repos/{repo}/commits?per_page=1"
    if path:
        api_url += f"&path={path}"
    body, code = run_curl(api_url, timeout=20)
    if not body or code != 200:
        print(f"    [github] API failed (http={code})", file=sys.stderr)
        return None, None
    try:
        data = json.loads(body)
        if not data:
            return None, None
        commit = data[0]
        sha = commit.get("sha", "")[:7]
        date = (commit.get("commit", {})
                      .get("committer", {})
                      .get("date") or
                commit.get("commit", {})
                      .get("author", {})
                      .get("date"))
        # Normalize ISO 8601: "2026-01-12T19:51:13Z" -> "2026-01-12 19:51:13"
        if date:
            date = date.replace("T", " ").rstrip("Z")
        return date, sha
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        print(f"    [github] parse error: {e}", file=sys.stderr)
        return None, None


def _fetch_fossil_date(base, module_path, meta):
    """
    Populate meta['last_commit'] and meta['last_commit_sha'].
    If module_path is given, filters the timeline to that subdirectory
    so we get the last commit that actually touched this module.
    Falls back to whole-repo timeline if the filtered request fails.
    """
    # --- 0. GitHub mirror API (most reliable for per-module dates) ---
    if base in FOSSIL_GIT_MIRRORS:
        mirror = FOSSIL_GIT_MIRRORS[base]
        print(f"    [fossil] trying GitHub API: {mirror} path={module_path}")
        date, sha = _github_api_commit(mirror, module_path)
        if date:
            meta["last_commit"] = date
            if sha:
                meta["last_commit_sha"] = sha
            print(f"    [fossil] GitHub API OK: commit={date}")
            return

    # --- 1. JSON API (often 404 on core.tcl-lang.org) ---
    timeline_url = f"{base}/json/timeline?type=ci&limit=1"
    if module_path:
        timeline_url += f"&p={module_path}"
    print(f"    [fossil] trying API: {timeline_url}")
    body, http_code = run_curl(timeline_url, timeout=20)
    if body and http_code == 200:
        try:
            data = json.loads(body)
            timeline = data.get('payload', {}).get('timeline') or data.get('timeline', [])
            if timeline:
                entry = timeline[0]
                meta["last_commit"] = entry.get('timestamp') or entry.get('mtime')
                sha = entry.get('uuid') or entry.get('hash')
                if sha:
                    meta["last_commit_sha"] = sha[:10]
                print(f"    [fossil] API OK: commit={meta['last_commit']}")
                return
        except json.JSONDecodeError as e:
            print(f"    [fossil] JSON parse error: {e}", file=sys.stderr)
    elif http_code == 404:
        print(f"    [fossil] JSON API not available (404), using HTML")
    else:
        print(f"    [fossil] API failed (http={http_code})", file=sys.stderr)

    # --- 2. HTML timeline filtered by module path ---
    timeline_html_url = f"{base}/timeline?n=1"
    if module_path:
        timeline_html_url += f"&p={module_path}"
    print(f"    [fossil] fetching HTML: {timeline_html_url}")
    html, http_code = run_curl(timeline_html_url, timeout=20)
    if html and http_code == 200:
        date, sha = parse_fossil_date_from_html(html)
        if date:
            meta["last_commit"] = date
            if sha:
                meta["last_commit_sha"] = sha
            print(f"    [fossil] HTML OK: commit={meta['last_commit']}")
            return
        else:
            snippet = re.sub(r'\s+', ' ', html[:300])
            print(f"    [fossil] HTML: no date in {len(html)} bytes. Snippet: {snippet}", file=sys.stderr)
    else:
        print(f"    [fossil] HTML failed (http={http_code})", file=sys.stderr)

    # --- 3. Fallback: whole-repo timeline (no path filter) ---
    if module_path:
        print(f"    [fossil] falling back to whole-repo timeline")
        html, http_code = run_curl(f"{base}/timeline?n=1", timeout=20)
        if html and http_code == 200:
            date, sha = parse_fossil_date_from_html(html)
            if date:
                meta["last_commit"] = date
                if sha:
                    meta["last_commit_sha"] = sha
                print(f"    [fossil] fallback OK: commit={meta['last_commit']}")
                return
    meta["error"] = "date_not_found"


def _fetch_fossil_tag(base, meta):
    """
    Populate meta['last_tag'].
    Tries: JSON API -> /taglist HTML -> /brlist HTML -> Git mirror.
    """
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

    if not tag and base in FOSSIL_GIT_MIRRORS:
        mirror = FOSSIL_GIT_MIRRORS[base]
        print(f"    [fossil] trying Git mirror for tags: {mirror}")
        tag = _latest_tag_from_git_mirror(mirror)
        if tag:
            print(f"    [fossil] tag from Git mirror: {tag}")

    if tag:
        meta["last_tag"] = tag
    else:
        print(f"    [fossil] no tag found", file=sys.stderr)


def process_fossil(url, temp_base):
    base = extract_fossil_base(url)
    module_path = _extract_module_path(url)
    print(f"    [fossil] base={base}  module={module_path or '(whole repo)'}")

    # --- Date: per-module cache (same module can appear in multiple packages) ---
    if url in _fossil_date_cache:
        print(f"    [fossil] date cache hit")
        date_meta = _fossil_date_cache[url]
    else:
        date_meta = {"last_commit": None, "last_commit_sha": None}
        _fetch_fossil_date(base, module_path, date_meta)
        _fossil_date_cache[url] = date_meta

    # --- Tags: per-repo cache ---
    if base in _fossil_repo_cache:
        print(f"    [fossil] tag cache hit")
        tag_meta = _fossil_repo_cache[base]
    else:
        tag_meta = {"last_tag": None}
        _fetch_fossil_tag(base, tag_meta)
        _fossil_repo_cache[base] = tag_meta

    return {**date_meta, **tag_meta}


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
