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


def run_curl(url, timeout=20, extra_headers=""):
    """
    Run curl and return (body, http_code).
    Captures HTTP status code separately (-w) to detect 4xx/5xx failures.
    """
    cmd = f'curl -s -L --max-time {timeout} {extra_headers} -w "\\n__HTTP_CODE__%{{http_code}}" "{url}"'
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


def check_url_reachable(url, timeout=10):
    """
    Check if a URL is reachable using a HEAD request.
    Returns (reachable: bool, http_code: int).
    Uses HEAD to avoid downloading the full body.
    Follows redirects (-L) so 301/302 to valid pages counts as reachable.
    """
    cmd = (
        f'curl -s -I -L --max-time {timeout} '
        f'-o /dev/null -w "%{{http_code}}" "{url}"'
    )
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout + 5
        )
        code_str = result.stdout.strip()
        http_code = int(code_str) if code_str.isdigit() else 0
        reachable = 200 <= http_code < 400
        return reachable, http_code
    except subprocess.TimeoutExpired:
        return False, 0
    except Exception:
        return False, 0


# Cache for GitHub repo metadata: "owner/repo" -> {archived, latest_release}
_github_repo_cache: dict = {}


def _parse_github_repo(url):
    """Extract 'owner/repo' from a GitHub URL, or None if not GitHub."""
    if m := re.match(r'https://github\.com/([^/]+/[^/.]+)', url):
        return m.group(1).rstrip('/')
    return None


def _fetch_github_repo_info(github_url):
    """
    Query GitHub API for repo metadata and latest release.
    Returns dict with keys: archived (bool), latest_release (str|None).
    Results are cached per repo to avoid duplicate API calls.
    """
    repo = _parse_github_repo(github_url)
    if not repo:
        return {"archived": None, "latest_release": None}

    if repo in _github_repo_cache:
        return _github_repo_cache[repo]

    token = os.environ.get("GITHUB_TOKEN", "")
    auth_header = f'-H "Authorization: Bearer {token}"' if token else ""
    base_headers = (
        f'{auth_header} '
        f'-H "Accept: application/vnd.github+json" '
        f'-H "X-GitHub-Api-Version: 2022-11-28"'
    )

    result = {"archived": None, "latest_release": None}

    # --- Repo info (archived status) ---
    body, code = run_curl(
        f"https://api.github.com/repos/{repo}",
        timeout=15,
        extra_headers=base_headers
    )
    if body and code == 200:
        try:
            data = json.loads(body)
            result["archived"] = data.get("archived", False)
        except json.JSONDecodeError:
            pass

    # --- Latest release ---
    body, code = run_curl(
        f"https://api.github.com/repos/{repo}/releases/latest",
        timeout=15,
        extra_headers=base_headers
    )
    if body and code == 200:
        try:
            data = json.loads(body)
            result["latest_release"] = data.get("tag_name")
        except json.JSONDecodeError:
            pass
    # 404 = no releases published, that's normal

    _github_repo_cache[repo] = result
    return result


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

    Auth: reads GITHUB_TOKEN env var (auto-injected by GitHub Actions).
    Without token: 60 req/h. With token: 5000 req/h.
    """
    m = re.match(r'https://github\.com/([^/]+/[^/.]+)', git_url)
    if not m:
        return None, None
    repo = m.group(1)
    api_url = f"https://api.github.com/repos/{repo}/commits?per_page=1"
    if module_path:
        api_url += f"&path={module_path}"

    # Use GITHUB_TOKEN if available (GitHub Actions injects it automatically)
    token = os.environ.get("GITHUB_TOKEN", "")
    auth_header = f'-H "Authorization: Bearer {token}"' if token else ""
    cmd = (
        f'curl -s -L --max-time 20 {auth_header} '
        f'-H "Accept: application/vnd.github+json" '
        f'-H "X-GitHub-Api-Version: 2022-11-28" '
        f'-w "\n__HTTP_CODE__%{{http_code}}" '
        f'"{api_url}"'
    )
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=25)
        output = result.stdout
        if "__HTTP_CODE__" in output:
            body, code_str = output.rsplit("__HTTP_CODE__", 1)
            http_code = int(code_str.strip()) if code_str.strip().isdigit() else 0
        else:
            body, http_code = output, 0
        body = body.strip()
    except Exception as e:
        print(f"    [github] curl error: {e}", file=sys.stderr)
        return None, None

    if http_code == 403:
        # Parse rate limit info if available
        try:
            msg = json.loads(body).get("message", "")
            print(f"    [github] rate limited: {msg[:80]}", file=sys.stderr)
        except Exception:
            print(f"    [github] HTTP 403 (rate limited?)", file=sys.stderr)
        return None, None
    if not body or http_code != 200:
        print(f"    [github] API failed (http={http_code})", file=sys.stderr)
        return None, None

    try:
        data = json.loads(body)
        if not data:
            return None, None
        commit = data[0]
        sha = commit.get("sha", "")[:7]
        date = (commit.get("commit", {}).get("committer", {}).get("date") or
                commit.get("commit", {}).get("author",    {}).get("date"))
        if date:
            date = date.replace("T", " ").rstrip("Z")
        return date, sha
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        print(f"    [github] parse error: {e}", file=sys.stderr)
        return None, None


def _fetch_fossil_date(base, module_path, meta):
    """
    Populate meta['last_commit'] and meta['last_commit_sha'].

    Strategy:
      1. Fossil JSON API — queried first (canonical source)
      2. GitHub mirror   — queried second (trusted for per-module accuracy)
      When both succeed: GitHub wins (more precise per-module granularity)
      When only one succeeds: use it
      3. Fossil HTML     — last resort only when 1 and 2 both fail,
                           whole-repo date, marked approximate
    """
    fossil_date, fossil_sha = None, None
    github_date, github_sha = None, None

    # --- 1. Fossil JSON API ---
    timeline_url = f"{base}/json/timeline?type=ci&limit=1"
    if module_path:
        timeline_url += f"&p={module_path}"
    body, http_code = run_curl(timeline_url, timeout=20)
    if body and http_code == 200:
        try:
            data = json.loads(body)
            timeline = data.get('payload', {}).get('timeline') or data.get('timeline', [])
            if timeline:
                entry = timeline[0]
                fossil_date = entry.get('timestamp') or entry.get('mtime')
                sha = entry.get('uuid') or entry.get('hash')
                fossil_sha = sha[:10] if sha else None
                print(f"    [fossil] JSON API: {fossil_date}")
        except json.JSONDecodeError as e:
            print(f"    [fossil] JSON parse error: {e}", file=sys.stderr)
    elif http_code == 404:
        print(f"    [fossil] JSON API not available (404)")
    else:
        print(f"    [fossil] JSON API failed (http={http_code})", file=sys.stderr)

    # --- 2. GitHub mirror ---
    if base in FOSSIL_GIT_MIRRORS:
        mirror = FOSSIL_GIT_MIRRORS[base]
        print(f"    [fossil] trying GitHub mirror: {mirror} path={module_path}")
        github_date, github_sha = _github_api_commit(mirror, module_path)
        if github_date:
            print(f"    [fossil] GitHub mirror: {github_date}")

    # --- Decision: GitHub trusted over Fossil when both present ---
    if github_date:
        meta["last_commit"] = github_date
        meta["last_commit_sha"] = github_sha
        if fossil_date:
            print(f"    [fossil] winner=GitHub: {github_date} (fossil={fossil_date})")
        else:
            print(f"    [fossil] winner=GitHub: {github_date}")
        return
    if fossil_date:
        meta["last_commit"] = fossil_date
        meta["last_commit_sha"] = fossil_sha
        print(f"    [fossil] winner=Fossil: {fossil_date}")
        return

    # --- 3. Fossil HTML — last resort, whole-repo, approximate ---
    print(f"    [fossil] trying HTML (whole-repo, approximate)")
    html, http_code = run_curl(f"{base}/timeline?n=1", timeout=20)
    if html and http_code == 200:
        date, sha = parse_fossil_date_from_html(html)
        if date:
            meta["last_commit"] = date
            meta["last_commit_sha"] = sha
            meta["last_commit_approximate"] = True
            print(f"    [fossil] HTML (approximate): {date}")
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

                # Check URL reachability first
                reachable, http_code = check_url_reachable(url)
                print(f"    [check] reachable={reachable} (http={http_code})")

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

                # GitHub repo metadata (archived, latest_release) for any GitHub URL
                # Works for native git sources AND Fossil mirrors
                # Returns None values for non-GitHub URLs
                gh_info = _fetch_github_repo_info(url)
                if gh_info["archived"] is None and method == "fossil":
                    # For Fossil sources, check if there's a known GitHub mirror
                    fossil_base = extract_fossil_base(url)
                    if fossil_base in FOSSIL_GIT_MIRRORS:
                        gh_info = _fetch_github_repo_info(FOSSIL_GIT_MIRRORS[fossil_base])
                if gh_info["archived"] is not None:
                    print(f"    [github] archived={gh_info['archived']}  release={gh_info['latest_release']}")

                enriched_source = {
                    **source,
                    "reachable": reachable,
                    "archived": gh_info["archived"],
                    "latest_release": gh_info["latest_release"],
                    **meta,
                }
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