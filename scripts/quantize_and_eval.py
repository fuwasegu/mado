import numpy as np, torch
import coremltools as ct
import coremltools.optimize.coreml as cto
from transformers import AutoTokenizer, AutoModel

# --- 1) 8-bit 量子化で mlpackage を圧縮 ---
src = "MultilingualE5Small.mlpackage"
mlmodel = ct.models.MLModel(src)
cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=512))
q = cto.linear_quantize_weights(mlmodel, config=cfg)
q.save("MultilingualE5Small-int8.mlpackage")
print("QUANTIZED saved")

# --- 2) e5 の日本語検索品質を実測(torch, spike2 と同一データ)---
NAME = "intfloat/multilingual-e5-small"
tok = AutoTokenizer.from_pretrained(NAME)
model = AutoModel.from_pretrained(NAME).eval()

def embed(texts, prefix):
    ins = tok([prefix + t for t in texts], padding=True, truncation=True, max_length=256, return_tensors="pt")
    with torch.no_grad():
        out = model(**ins).last_hidden_state
    mask = ins["attention_mask"].unsqueeze(-1).float()
    mean = (out * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
    return torch.nn.functional.normalize(mean, p=2, dim=1).numpy()

corpus = [
    "ユーザー登録ではメールアドレスとパスワードを受け取り確認メールを送る",
    "ログイン認証はOAuth2を用い、アクセストークンを発行して有効期限を管理する",
    "リフレッシュトークンを使ってセッションを更新し、ローテーションする",
    "支払い処理はStripeを経由し、Webhookで決済完了を受け取る",
    "CSVファイルはRFC4180準拠でパースし、ヘッダを固定して行番号を付ける",
    "MermaidのコードブロックはSVGに描画してキャッシュする",
    "OpenAPIドキュメントはRedocで表示し、外部$refを解決する",
    "ダークモードに追従してテーマを切り替える",
]
queries = [
    ("サインインの仕組みとトークンの発行手順は?", 1),
    ("会員のアカウント作成フローを知りたい", 0),
    ("クレジットカード決済の連携方法", 3),
    ("表形式データの読み込みと表示", 4),
    ("図表のレンダリングとキャッシュ", 5),
]
C = embed(corpus, "passage: ")
top1 = 0; mrr = 0.0
for q_text, gold in queries:
    qv = embed([q_text], "query: ")[0]
    sims = C @ qv
    order = np.argsort(-sims)
    if order[0] == gold: top1 += 1
    rank = list(order).index(gold) + 1
    mrr += 1.0 / rank
    print(f"  Q『{q_text}』 gold={gold} top={order[0]} sims_gold={sims[gold]:.3f} best={sims[order[0]]:.3f}")
print(f"e5: top1={top1}/{len(queries)} MRR={mrr/len(queries):.3f}  (NLEmbedding は top1=2/5 MRR=0.557)")
