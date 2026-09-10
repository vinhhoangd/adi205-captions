#!/bin/bash
# Runs the bench across clips and settings, one process each (models are
# per-process, so this also re-measures cold start every time).
set -u
APP="$(cd "$(dirname "$0")" && pwd)/build/CaptionBench.app"
CORPUS="${CORPUS_DIR:?set CORPUS_DIR}"
GLOSS="Bayes,eigenvector,covariance,posterior,heteroscedastic,transformer,encoder,decoder,tokenizer,softmax,gradient,perceptron"
for clip in "$@"; do
  for k in 3 0; do
    out="/tmp/m_$(basename "$clip" .wav)_k$k.txt"; rm -f "$out" "$out.err"
    BENCH_GLOSSARY="$GLOSS" BENCH_MASK_K=$k \
      open -a "$APP" --args -out "$out" "$CORPUS/$clip"
    while pgrep -f CaptionBench >/dev/null; do sleep 2; done
    echo "=========== $clip  mask-k=$k ==========="
    sed -n '/^ *n *median/,/^$/p;/translate calls/,/correction calls/p' "$out"
  done
done
