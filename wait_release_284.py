"""轮询 v2.8.4 Release：构建完成后输出 IPA 下载直链。"""
import json
import time
import urllib.request

REPO = "zhangwenwei44/Bei-"
TAG = "v2.8.4"
UA = "aurora-poller"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    except Exception as e:
        print(f"  (net: {type(e).__name__})", flush=True)
        return None


def build_status():
    d = fetch(f"https://api.github.com/repos/{REPO}/actions/runs?per_page=5")
    if not d:
        return "?"
    for r in d.get("workflow_runs", []):
        if r.get("head_branch") == TAG:
            return f"{r.get('status')}/{r.get('conclusion')}"
    return "?"


deadline = time.time() + 35 * 60
attempt = 0
while time.time() < deadline:
    attempt += 1
    rel = fetch(f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}")
    if rel and rel.get("assets"):
        print("RELEASE READY", flush=True)
        for a in rel["assets"]:
            print(f"ASSET|{a['name']}|{a['size']}|{a['browser_download_url']}", flush=True)
        raise SystemExit(0)
    print(f"attempt {attempt}: release not ready (build: {build_status()})", flush=True)
    time.sleep(30)

print("TIMEOUT", flush=True)
raise SystemExit(1)
