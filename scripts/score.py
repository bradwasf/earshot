#!/usr/bin/env python3
"""Scores an Earshot transcript.md against reference.json from make-test-call.py.

Reports word error rate per channel (Me / Them) and how consistently remote speakers were
told apart. Standard library only. Usage: scripts/score.py <transcript.md> <reference.json>
"""
import json, re, sys
from collections import Counter, defaultdict

NUMBERS = {"3rd": "third", "10th": "tenth", "1": "one", "2": "two", "5": "five", "42000": "forty two thousand",
           "60000": "sixty thousand", "42": "forty two", "60": "sixty", "okay": "ok", "forty-two": "forty two"}


def words(text):
    text = text.lower().replace(",000", "000").replace("$", " ").replace("-", " ")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    out = []
    for token in text.split():
        out.extend(NUMBERS.get(token, token).split())
    return out


def edit_distance(ref, hyp):
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        current = [i]
        for j, h in enumerate(hyp, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r != h)))
        previous = current
    return previous[-1]


def seconds(stamp):
    parts = [int(p) for p in stamp.split(":")]
    return sum(p * 60 ** i for i, p in enumerate(reversed(parts)))


def main():
    transcript, reference = sys.argv[1], json.load(open(sys.argv[2]))
    turns = []
    for line in open(transcript):
        match = re.match(r"\*\*\[([\d:]+)\] (.+?):\*\* (.*)", line)
        if match:
            turns.append((seconds(match.group(1)), match.group(2), match.group(3).strip()))

    total_errors = total_words = 0
    for channel in ("Me", "Them"):
        ref = [w for r in reference if r["speaker"].startswith(channel) for w in words(r["text"])]
        hyp = [w for _, label, text in turns if label.startswith(channel) for w in words(text)]
        errors = edit_distance(ref, hyp)
        total_errors += errors
        total_words += len(ref)
        print(f"{channel:5s} WER {100 * errors / max(1, len(ref)):5.2f}%  ({errors} errors / {len(ref)} words; {len(hyp)} transcribed)")
    print(f"Total WER {100 * total_errors / max(1, total_words):5.2f}%")

    # Speaker attribution: map each transcript turn to the reference line with the most word overlap.
    votes = defaultdict(Counter)
    for start, label, text in turns:
        if not label.startswith("Them"):
            continue
        bag = Counter(words(text))
        best = max((r for r in reference if r["speaker"].startswith("Them")),
                   key=lambda r: sum((bag & Counter(words(r["text"]))).values()) - abs(r["start"] - start) * 0.05)
        votes[label][best["speaker"]] += len(words(text))
    if votes:
        correct = sum(max(c.values()) for c in votes.values())
        total = sum(sum(c.values()) for c in votes.values())
        print("Remote speaker labels:", {label: dict(c) for label, c in votes.items()})
        print(f"Diarization purity {100 * correct / max(1, total):.1f}% of remote words ({len(votes)} label(s) for "
              f"{len({r['speaker'] for r in reference if r['speaker'].startswith('Them')})} real speakers)")


if __name__ == "__main__":
    main()
