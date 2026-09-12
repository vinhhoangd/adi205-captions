import json, time, urllib.request

SYS = ("You repair speech-recognition output from a university lecture.\n"
       "Fix only words that were clearly misheard. Preserve the original wording, "
       "punctuation and capitalisation everywhere else. If nothing is wrong, return "
       "the input unchanged. Reply with the corrected sentence and nothing else.")

# (input, must_contain, must_not_contain)  — must_contain None means "leave it alone"
CASES = [
    ("The eigon vector of the covariance matrix gives the principal component.", "eigenvector", "eigen vector"),
    ("The encoder produces a hidden stake for every token.", "hidden state", "hidden stake"),
    ("We minimise the error using gradient dissent.", "gradient descent", "dissent"),
    ("Bayes theorem updates a prior into a postrior.", "posterior", "postrior"),
    ("We use cross entropy lost for classification.", "cross entropy loss", "entropy lost"),
    ("Stochastic grade in descent converges faster here.", "gradient descent", "grade in"),
    ("The model is over fitting the training set.", "overfitting", "over fitting"),
    ("This is principle component analysis.", "principal component", "principle component"),
    ("A neural net work learns these weights.", "network", "net work"),
    ("The learning rate is to high for stable training.", "too high", "is to high"),
    ("Back propagation computes the gradients.", "Backpropagation", None),
    ("We assume a normal distribution with mean mew.", "mu", "mew"),
    # No-error controls: a good corrector changes nothing here.
    ("The sigmoid function is monotonic and differentiable.", None, None),
    ("The dataset is imbalanced across the three classes.", None, None),
    ("Attention lets the decoder look at every encoder state.", None, None),
]

def ask(model, text):
    body = json.dumps({
        "model": model, "temperature": 0, "max_tokens": 120, "stream": False,
        "messages": [{"role": "system", "content": SYS},
                     {"role": "user", "content": "Transcript: " + text}],
    }).encode()
    req = urllib.request.Request("http://localhost:11434/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)["choices"][0]["message"]["content"].strip()
    return out, (time.time() - t) * 1000

for model in ["qwen2.5:1.5b", "llama3.1:8b"]:
    try: ask(model, "warm up")   # load weights; not counted
    except Exception as e: print(model, "unavailable:", e); continue
    fixed = missed = damaged = 0
    times = []
    detail = []
    for text, want, avoid in CASES:
        out, ms = ask(model, text)
        times.append(ms)
        low = out.lower()
        if want is None:
            # control: must leave the sentence essentially alone
            ok = out.rstrip(".").lower() == text.rstrip(".").lower()
            if ok: fixed += 1
            else:
                damaged += 1
                detail.append(f"      CHANGED A CORRECT LINE: {out[:80]}")
        else:
            hit = want.lower() in low
            bad = avoid is not None and avoid.lower() in low
            if hit and not bad: fixed += 1
            else:
                missed += 1
                detail.append(f"      missed [{want}]: {out[:80]}")
        time.sleep(0.05)
    times.sort()
    n = len(CASES)
    print(f"\n{model}")
    print(f"  correct        {fixed}/{n}")
    print(f"  missed fix     {missed}")
    print(f"  broke a good line {damaged}")
    print(f"  median {times[len(times)//2]:.0f} ms   p90 {times[int(len(times)*0.9)]:.0f} ms")
    for d in detail: print(d)
