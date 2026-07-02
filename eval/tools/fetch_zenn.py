# zenn.dev/mizchi から最新記事を ~100 本、front matter 付き markdown で取得する。
import os, re, time, json, html
import requests
from markdownify import markdownify as md

USER = "mizchi"
TARGET = 100
OUT = "zenn-corpus"
UA = {"User-Agent": "mado-eval/0.1 (research)"}
os.makedirs(OUT, exist_ok=True)

def slugify_topics(topics):
    return [t.get("name") for t in (topics or []) if t.get("name")]

# 1) 記事一覧をページング
articles = []
page = 1
while len(articles) < TARGET:
    r = requests.get("https://zenn.dev/api/articles",
                     params={"username": USER, "order": "latest", "page": page},
                     headers=UA, timeout=20)
    r.raise_for_status()
    d = r.json()
    batch = [a for a in d.get("articles", []) if a.get("post_type") == "Article"]
    articles += batch
    nxt = d.get("next_page")
    print(f"page {page}: +{len(batch)} (total {len(articles)}) next={nxt}")
    if not nxt:
        break
    page = nxt
    time.sleep(0.3)

articles = articles[:TARGET]

# 2) 各記事の本文を取得して md 化
manifest = []
for i, a in enumerate(articles):
    slug = a["slug"]
    try:
        rd = requests.get(f"https://zenn.dev/api/articles/{slug}", headers=UA, timeout=20)
        rd.raise_for_status()
        art = rd.json()["article"]
    except Exception as e:
        print("skip", slug, e); continue

    body_html = art.get("body_html") or ""
    body_md = md(body_html, heading_style="ATX", bullets="-").strip()
    title = (art.get("title") or slug).replace('"', "'")
    date = (art.get("published_at") or "")[:10]
    topics = slugify_topics(art.get("topics"))
    emoji = art.get("emoji") or ""

    fm = ["---",
          f'title: "{title}"',
          f"date: {date}",
          f"tags: [{', '.join(topics)}]",
          f'emoji: "{emoji}"',
          f"slug: {slug}",
          "---", ""]
    content = "\n".join(fm) + f"# {title}\n\n" + body_md + "\n"
    with open(os.path.join(OUT, f"{slug}.md"), "w") as f:
        f.write(content)
    manifest.append({"slug": slug, "title": art.get("title"), "date": date,
                     "tags": topics, "letters": art.get("body_letters_count")})
    if i % 10 == 0:
        print(f"[{i+1}/{len(articles)}] {slug}  ({art.get('body_letters_count')} chars, tags={topics[:3]})")
    time.sleep(0.25)

with open("zenn-manifest.json", "w") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=1)

total_chars = sum(m.get("letters") or 0 for m in manifest)
print(f"DONE: {len(manifest)} articles, ~{total_chars:,} chars, saved to {OUT}/")
