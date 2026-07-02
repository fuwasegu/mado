# multilingual-e5-small を CoreML(.mlpackage)へ変換する。
# mean-pooling + L2 正規化までモデルに焼き込むので、Swift は tokenize→predict で 384 次元を得るだけ。
import numpy as np
import torch
import coremltools as ct
from transformers import AutoTokenizer, AutoModel

NAME = "intfloat/multilingual-e5-small"
SEQ = 256
OUT = "MultilingualE5Small.mlpackage"

tok = AutoTokenizer.from_pretrained(NAME)
model = AutoModel.from_pretrained(NAME).eval()


class E5Embed(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids, attention_mask):
        out = self.m(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(out.dtype)
        summed = (out * mask).sum(dim=1)
        counts = mask.sum(dim=1).clamp(min=1e-9)
        mean = summed / counts
        return torch.nn.functional.normalize(mean, p=2, dim=1)


wrapped = E5Embed(model).eval()
ids = torch.ones(1, SEQ, dtype=torch.long)
am = torch.ones(1, SEQ, dtype=torch.long)
with torch.no_grad():
    traced = torch.jit.trace(wrapped, (ids, am))

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, SEQ), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, SEQ), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
mlmodel.short_description = "multilingual-e5-small: mean-pooled, L2-normalized sentence embedding (384d)"
mlmodel.save(OUT)
print("SAVED", OUT, "SEQ", SEQ, "dim", model.config.hidden_size)

# トークナイザ一式も書き出す(swift-transformers が読む)
tok.save_pretrained("e5-tokenizer")
print("TOKENIZER saved to e5-tokenizer/")
