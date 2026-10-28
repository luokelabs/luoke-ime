# 个人化组件的模型打分器（由 ime_eval/lm_scorer.py 而来；原先在小鹤、全拼引擎里，第 2 期搬到这里）。
# 协议：每行 {"ctx","cands"} → {"lp","ms"}（打分）；{"branches","k","max_tokens","stop"} → {"branches","ms"}（通用的续写，和主控的
# /v1/continue 一样；联想怎么截、挑哪几个在 personal.py）。
"""Score IME candidates with a small local LM: log P(candidate | left context).

Line protocol on stdin/stdout, one JSON object per line:
    in:  {"ctx": "前文", "cands": ["候选一", "候选二", ...]}
    out: {"lp": [-3.1, -7.4, ...], "ms": 12.3}

All candidates are scored in one padded batch, from a token boundary shared by
every candidate (the last context character can merge with the candidate's
first one into a single token, so per-candidate boundaries are not comparable).

Needs mlx_lm, which system python3 lacks — run it with oMLX's bundled Python:
    PYTHONPATH=/Applications/oMLX.app/Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages \
    /Applications/oMLX.app/Contents/Resources/Python/cpython-3.11/bin/python3.11 lm_scorer.py <model_dir>
"""

import json
import os
import sys
import threading
import time
from collections import OrderedDict

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import ArraysCache, KVCache, make_prompt_cache

PREFIX = "\n"  # every context gets this, so an empty context still has a token to predict from

# MLX keeps freed GPU buffers for reuse, by default up to a large share of the machine's memory. Every request has a
# different shape (full-vocabulary logits for each candidate position: ~200 MB for 16 candidates), so the cache only
# grows: 14 GB after 500 requests on an M5 Max, 13 GB (swapped out) on a 32 GB M4 after five days. Cap it, and drop it
# when idle. Replaying 2000 rerank-shaped requests: uncapped 16 GB footprint, p50 / p90 14 / 19 ms; 1 GB cap 2.5 GB,
# 15-16 / 22-25 ms; 512 MB 2.0 GB, 17-18 / 25-26 ms.
CACHE_MB = int(os.environ.get("LUOKE_SCORER_CACHE_MB", "1024"))
IDLE_CLEAR = 30  # seconds without a request before the cache is dropped


def tokenize(tok, ctx, cands):
    """Token ids of ctx+cand for each candidate, and the boundary k0 every candidate shares."""
    ctx = PREFIX + ctx
    ctx_ids = tok.encode(ctx)
    seqs, shared = [], []
    for c in cands:
        full = tok.encode(ctx + c)
        k = 0
        while k < min(len(ctx_ids), len(full)) and ctx_ids[k] == full[k]:
            k += 1
        seqs.append(full)
        shared.append(k)
    return seqs, max(min(shared), 1)


class PrefixStore:
    """Snapshots of the model state after a token prefix, so a request whose prefix extends one
    seen before only runs the new tokens. Within one corrector decision the stepwise search asks
    for ctx, ctx+w1, ctx+w1+w2, … and the final scoring asks for ctx again.

    Qwen3.5's Gated DeltaNet state can't be rewound, but it can be carried forward. Snapshots
    hold exact-size slices of the KV arrays: the next update then has to reallocate instead of
    writing into a stored array in place.
    """

    def __init__(self, model, size=16):
        self.model, self.size, self.store = model, size, OrderedDict()

    @staticmethod
    def _snap(cache):
        out = []
        for c in cache:
            if isinstance(c, KVCache):
                out.append(("kv", c.keys[..., :c.offset, :], c.values[..., :c.offset, :], c.offset))
            else:
                out.append(("arr", list(c.cache)))
        return out

    def _restore(self, snap):
        cache = make_prompt_cache(self.model)
        for c, s in zip(cache, snap):
            if s[0] == "kv":
                c.keys, c.values, c.offset = s[1], s[2], s[3]
            else:
                c.cache = list(s[1])
        return cache

    def prefix(self, tokens):
        """(cache positioned after `tokens`, log-probs of the next token)."""
        key = tuple(tokens)
        best = max((k for k in self.store if len(k) <= len(key) and key[:len(k)] == k), key=len, default=None)
        if best is None:
            cache, done, last = make_prompt_cache(self.model), 0, None
        else:
            self.store.move_to_end(best)
            cache, done, last = self._restore(self.store[best][0]), len(best), self.store[best][1]
        if done < len(key):
            logits = self.model(mx.array([list(key[done:])]), cache=cache)[:, -1, :].astype(mx.float32)
            last = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
            mx.eval(last)
            self.store[key] = (self._snap(cache), last)
            while len(self.store) > self.size:
                self.store.popitem(last=False)
        return cache, last


def score_cached(model, tok, ctx, cands, store=None):
    """Run the shared prefix once (or extend a stored one), copy its state per candidate, then
    score only the candidate tokens in one batch.

    Qwen3.5 mixes attention (KVCache) with Gated DeltaNet layers (ArraysCache: conv + recurrent
    state). A recurrent state can't be trimmed back, but it can be repeated along the batch axis,
    which is all a shared prefix needs.
    """
    seqs, k0 = tokenize(tok, ctx, cands)
    cache, first = (store or PrefixStore(model, size=1)).prefix(seqs[0][:k0])
    n = len(seqs)
    for c in cache:
        if isinstance(c, KVCache):
            c.keys, c.values = mx.repeat(c.keys, n, axis=0), mx.repeat(c.values, n, axis=0)
        elif isinstance(c, ArraysCache):
            c.cache = [None if a is None else mx.repeat(a, n, axis=0) for a in c.cache]
    rest = [s[k0:] for s in seqs]
    width = max(len(r) for r in rest)
    if width == 0:
        return [float("-inf")] * n
    pad = tok.pad_token_id if tok.pad_token_id is not None else 0
    tgt = mx.array([r + [pad] * (width - len(r)) if r else [pad] * width for r in rest])
    total = first[0][tgt[:, 0]]
    if width > 1:
        # 所有候选一起取分、一次同步：逐个 .item() 每次都要等 GPU
        logits = model(tgt[:, :-1], cache=cache).astype(mx.float32)
        picked = mx.take_along_axis(logits, tgt[:, 1:, None], axis=-1)[..., 0] - mx.logsumexp(logits, axis=-1)
        mask = mx.array([[float(i < len(r) - 1) for i in range(width - 1)] for r in rest])
        total = total + (picked * mask).sum(axis=1)
    out = total.tolist()
    return [x if r else float("-inf") for x, r in zip(out, rest)]


def branches(model, tok, ctx, store, k=8, steps=6, stop=()):
    """General continuation, the same as the hub's /v1/continue (luoke-ime docs/续写接口草案.md): the k likeliest
    first tokens after ctx, each extended greedily until `steps` tokens, end of text, or one of the caller's stop
    strings shows up in the decoded text. Returns [{"tokens": [{"text", "logprob"}], "finish": "stop"|"length"|"eos"}],
    by the first token's log-prob. Each token's text is what decoding it adds (empty for the leading bytes of a
    character split across tokens). Nothing is cut, merged or dropped here: that is the IME's call (personal.py)."""
    ids = tok.encode(PREFIX + ctx)
    cache, first = store.prefix(ids)
    top = mx.argsort(-first[0])[:k]
    lp0 = first[0][top]
    mx.eval(top, lp0)
    n = len(top.tolist())
    for c in cache:
        if isinstance(c, KVCache):
            c.keys, c.values = mx.repeat(c.keys, n, axis=0), mx.repeat(c.values, n, axis=0)
        elif isinstance(c, ArraysCache):
            c.cache = [None if a is None else mx.repeat(a, n, axis=0) for a in c.cache]
    seqs = [[t] for t in top.tolist()]
    lps = [[lp] for lp in lp0.tolist()]
    eos = getattr(tok, "eos_token_ids", None) or {tok.eos_token_id}

    def decoded(seq):
        return tok.decode(seq).replace("\ufffd", "")

    def finished(i):
        if any(x and x in decoded(seqs[i]) for x in stop):
            return "stop"
        if seqs[i][-1] in eos:
            return "eos"
        return "length" if len(seqs[i]) >= steps else None

    finish = [finished(i) for i in range(n)]
    toks = top[:, None]
    while any(f is None for f in finish):
        logits = model(toks, cache=cache)[:, -1, :].astype(mx.float32)
        lp = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        nxt = mx.argmax(lp, axis=-1)
        step = mx.take_along_axis(lp, nxt[:, None], axis=-1)[:, 0]
        mx.eval(nxt, step)
        for i, (t, l) in enumerate(zip(nxt.tolist(), step.tolist())):
            if finish[i] is None:
                seqs[i].append(t)
                lps[i].append(l)
                finish[i] = finished(i)
        toks = nxt[:, None]
    out = []
    for seq, lp_list, f in zip(seqs, lps, finish):
        pieces, prev = [], ""
        for j, l in enumerate(lp_list):
            if seq[j] in eos:  # the end-of-text token is there too, with empty text (same as the hub)
                pieces.append({"text": "", "logprob": l})
                continue
            cur = decoded([t for t in seq[:j + 1] if t not in eos])
            pieces.append({"text": cur[len(prev):] if cur.startswith(prev) else cur, "logprob": l})
            prev = cur
        out.append({"tokens": pieces, "finish": f})
    return out


def score(model, tok, ctx, cands):
    """Reference path: every candidate re-reads the whole context (IME_LM_NOCACHE=1)."""
    seqs, k0 = tokenize(tok, ctx, cands)
    width = max(len(s) for s in seqs)
    pad = tok.pad_token_id if tok.pad_token_id is not None else 0
    logits = model(mx.array([s + [pad] * (width - len(s)) for s in seqs])).astype(mx.float32)
    logp = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
    mx.eval(logp)
    out = []
    for i, s in enumerate(seqs):
        if len(s) <= k0:
            out.append(float("-inf"))
            continue
        tgt = mx.array(s[k0:])
        out.append(logp[i, k0 - 1:len(s) - 1][mx.arange(len(s) - k0), tgt].sum().item())
    return out


def drop_cache_when_idle(lock, last):
    """Background thread: after IDLE_CLEAR seconds without a request, give the cached buffers back."""
    while True:
        time.sleep(IDLE_CLEAR / 3)
        with lock:
            if last[0] is not None and time.monotonic() - last[0] > IDLE_CLEAR:
                mx.clear_cache()
                last[0] = None  # nothing more to drop until the next request


def main():
    mx.set_cache_limit(CACHE_MB * 2 ** 20)
    model, tok = load(sys.argv[1])
    if os.environ.get("IME_LM_NOCACHE") == "1":
        fn = score
    elif os.environ.get("IME_LM_NOSTORE") == "1":  # prefix cache per call only (for comparisons)
        fn = score_cached
    else:
        store = PrefixStore(model)
        def fn(m, t, ctx, cands):
            return score_cached(m, t, ctx, cands, store)
    fn(model, tok, "预热", ["一下", "已下"])
    gen_store = store if fn is not score and fn is not score_cached else PrefixStore(model, size=4)
    branches(model, tok, "预热", gen_store, k=2, steps=2)
    lock, last = threading.Lock(), [time.monotonic()]
    threading.Thread(target=drop_cache_when_idle, args=(lock, last), daemon=True).start()
    print(json.dumps({"ready": sys.argv[1], "cached": fn is not score}), flush=True)
    for line in sys.stdin:
        req = json.loads(line)
        with lock:
            t = time.perf_counter()
            if "branches" in req:
                got = branches(model, tok, req["branches"], gen_store, k=req.get("k", 8), steps=req.get("max_tokens", 6),
                               stop=req.get("stop") or ())
                out = {"branches": got, "ms": (time.perf_counter() - t) * 1000}
            else:
                lp = fn(model, tok, req["ctx"], req["cands"]) if req["cands"] else []
                out = {"lp": lp, "ms": (time.perf_counter() - t) * 1000}
            last[0] = time.monotonic()
        print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
