import os, re, json, random
random.seed(42)
CORPUS = "zenn-corpus"
queries = []

def strip_fm_and_code(text):
    # front matter 除去
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end >= 0: text = text[end+4:]
    # コードフェンス除去
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return text

for fn in sorted(os.listdir(CORPUS)):
    if not fn.endswith(".md"): continue
    slug = fn[:-3]
    raw = open(os.path.join(CORPUS, fn)).read()
    # title from front matter
    mt = re.search(r'title:\s*"(.+?)"', raw)
    title = mt.group(1) if mt else slug
    body = strip_fm_and_code(raw)

    # title → article
    queries.append({"query": title, "gold": fn, "type": "title"})

    # headings(H2/H3、記号だけ/短すぎを除外)
    heads = []
    for m in re.finditer(r'^#{2,3}\s+(.+)$', body, flags=re.M):
        h = m.group(1).strip()
        h = re.sub(r'[`*_\[\]()#]', '', h).strip()
        if len(h) >= 6 and not h.startswith("http"):
            heads.append(h)
    for h in random.sample(heads, min(2, len(heads))):
        queries.append({"query": h, "gold": fn, "type": "heading"})

    # sentences(本文の文、25〜140字)
    plain = re.sub(r'^#{1,6}\s+.*$', '', body, flags=re.M)      # 見出し行除去
    plain = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', plain)       # リンク→テキスト
    plain = re.sub(r'[`*_>|-]', ' ', plain)
    sents = re.split(r'[。\n]', plain)
    cands = [s.strip() for s in sents if 25 <= len(s.strip()) <= 140]
    for s in random.sample(cands, min(2, len(cands))):
        queries.append({"query": s, "gold": fn, "type": "sentence"})

by = {}
for q in queries: by[q["type"]] = by.get(q["type"], 0) + 1
json.dump(queries, open("queries_auto.json", "w"), ensure_ascii=False, indent=0)
print("generated:", by, "total", len(queries))

# 意味クエリ作成用に全タイトルを出力
mani = json.load(open("zenn-manifest.json"))
with open("titles.txt", "w") as f:
    for a in mani:
        f.write(f"{a['slug']}\t{a['title']}\t{','.join(a['tags'][:4])}\n")
print("titles.txt written")
