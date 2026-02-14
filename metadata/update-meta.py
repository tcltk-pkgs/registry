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
        return None
    except Exception:
        return None

def process_git(url, temp_base):
    tmpdir = os.path.join(temp_base, f"git-{int(datetime.now().timestamp())}-{random.randint(0, 1000)}")
    
    meta = {
        "last_commit": None,
        "last_commit_sha": None,
        "last_tag": None
    }
    
    try:
        result = run_cmd(f'git clone --depth 1 --filter=blob:none --no-checkout "{url}" "{tmpdir}"', timeout=30)
        if result is None:
            print(f"    Git clone error: {url}", file=sys.stderr)
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
            tags = tags_output.split('\n')
            if tags and tags[0].strip():
                meta["last_tag"] = tags[0].strip()
                
    except Exception as e:
        print(f"    Git error: {e}", file=sys.stderr)
    finally:
        if os.path.exists(tmpdir):
            shutil.rmtree(tmpdir, ignore_errors=True)
    
    return meta

def process_fossil(url, temp_base):
    meta = {
        "last_commit": None,
        "last_commit_sha": None,
        "last_tag": None
    }
    
    base = url
    if match := re.match(r'^(https?://[^/]+/[^/]+)', url):
        base = match.group(1)
    else:
        base = url.split('?')[0].rstrip('/')
    
    try:
        timeline_url = f"{base}/json/timeline?type=ci&limit=1"
        print(f"    Trying API: {timeline_url}")
        
        json_data = run_cmd(f'curl -s -L --max-time 15 "{timeline_url}"', timeout=20)
        if json_data:
            try:
                data = json.loads(json_data)
                if 'timeline' in data and len(data['timeline']) > 0:
                    entry = data['timeline'][0]
                    if 'timestamp' in entry:
                        meta["last_commit"] = entry['timestamp']
                    if 'uuid' in entry:
                        meta["last_commit_sha"] = entry['uuid'][:10]
                    print(f"    API success: {meta['last_commit']}")
            except json.JSONDecodeError:
                pass
        
        if not meta["last_commit"]:
            print("    API failed, using HTML fallback", file=sys.stderr)
            html = run_cmd(f'curl -s -L --max-time 15 "{base}/timeline"', timeout=20)
            if html:
                if match := re.search(r'datetime="(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"', html):
                    meta["last_commit"] = match.group(1)
                if match := re.search(r'href="/timeline\?c=([0-9a-f]{10,})"', html):
                    meta["last_commit_sha"] = match.group(1)[:10]
        
        tags_url = f"{base}/json/taglist"
        tags_json = run_cmd(f'curl -s -L --max-time 10 "{tags_url}"', timeout=15)
        if tags_json:
            try:
                data = json.loads(tags_json)
                if 'tags' in data and len(data['tags']) > 0:
                    tag_name = data['tags'][0].get('tagname')
                    if tag_name:
                        meta["last_tag"] = tag_name
                        print(f"    Found tag: {tag_name}")
            except json.JSONDecodeError:
                pass
                
    except Exception as e:
        print(f"    Fossil error: {e}", file=sys.stderr)
    
    return meta

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
                print(f"  -> {method}: {url[:60]}...")
                
                if method == 'git':
                    meta = process_git(url, temp_base)
                elif method == 'fossil':
                    meta = process_fossil(url, temp_base)
                else:
                    meta = {
                        "last_commit": None,
                        "last_commit_sha": None,
                        "last_tag": None,
                        "error": "unknown_method"
                    }
                
                enriched_source = {**source, **meta}
                enriched_sources.append(enriched_source)
            
            new_package = {
                "name": package['name'],
                "sources": enriched_sources,
                "tags": package.get('tags', []),
                "description": package.get('description', '')
            }
            enriched_packages.append(new_package)
    
    meta_header = {
        "packages": "Tcl/Tk",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    }
    
    final_output = [meta_header] + enriched_packages
    
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, separators=(',',':'), ensure_ascii=False)
        # json.dump(final_output, f, indent=2, ensure_ascii=False)
    
    file_size = os.path.getsize(OUTPUT_FILE)
    print(f"File generated: {OUTPUT_FILE} ({file_size} bytes)")

if __name__ == "__main__":
    main()