#!/bin/bash
# Regenerates the test corpus. The audio itself is not in git — it is derived,
# and committing binaries that a command can rebuild is how repositories rot.
#
# Synthetic speech, deliberately: it is identical on every run, so a latency or
# accuracy number measured today is comparable with one measured next week.
# It is also easier than the truth: a real lecturer at real distance will score
# worse, and the report should say so.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p corpus

say_line () {   # $1 = index, $2 = text
  say -v Samantha -r 165 -o "corpus/raw$1.aiff" "$2"
  ffmpeg -hide_banner -loglevel error -y \
    -i "corpus/raw$1.aiff" -vn -ac 1 -ar 16000 -c:a pcm_f32le "corpus/lecture$1.wav"
  rm -f "corpus/raw$1.aiff"
  printf "  corpus/lecture%s.wav  %s\n" "$1" "$(printf '%.60s…' "$2")"
}

echo "Generating test corpus…"
say_line 1 "Today we will look at how a transformer model handles attention. \
The encoder produces a hidden state for every token, and the decoder attends over those states."
say_line 2 "Bayes theorem lets us update a prior into a posterior. \
The eigenvector of the covariance matrix gives us the principal component."

cat <<'EOF'

Reference transcripts (for word-error-rate scoring):

  1  Today we will look at how a transformer model handles attention. The
     encoder produces a hidden state for every token, and the decoder attends
     over those states.
  2  Bayes theorem lets us update a prior into a posterior. The eigenvector of
     the covariance matrix gives us the principal component.

Now measure:

  ./make_app.sh bench CaptionBench
  BENCH_GLOSSARY="Bayes,eigenvector,covariance,posterior,transformer" \
    open -a build/CaptionBench.app --args -out /tmp/bench.txt "$PWD/corpus/lecture2.wav"
  cat /tmp/bench.txt
EOF
