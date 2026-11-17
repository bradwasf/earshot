#!/bin/bash
# Earshot setup: builds the app, downloads the on-device speech models and makes sure a local
# summary model is available in Ollama.
#
#   ./setup.sh                    build + models (recommended; uses the native system-audio tap)
#   ./setup.sh --with-blackhole   also install the BlackHole 2ch loopback driver (fallback capture path)
#   ./setup.sh --install          also copy Earshot.app to /Applications
#
# Network use: Swift packages (GitHub), speech models (HuggingFace), the summary model (Ollama
# registry) and, optionally, Homebrew. After setup, Earshot itself only talks to the network when
# you choose "Send to Slack" for a call summary.
set -euo pipefail
cd "$(dirname "$0")"

SUMMARY_MODEL="${EARSHOT_SUMMARY_MODEL:-qwen3.5:4b-mlx}"
WITH_BLACKHOLE=0
INSTALL=0
for argument in "$@"; do
    case "$argument" in
        --with-blackhole) WITH_BLACKHOLE=1 ;;
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "Earshot only runs on macOS."
[ "$(uname -m)" = "arm64" ] || die "Earshot needs Apple Silicon (the speech models are Core ML, arm64 only)."
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
OS_MINOR="$(echo "$OS_VERSION" | cut -d. -f2)"
if [ "$OS_MAJOR" -lt 14 ] || { [ "$OS_MAJOR" -eq 14 ] && [ "${OS_MINOR:-0}" -lt 4 ]; }; then
    die "macOS 14.4 or newer is required for the system-audio tap (found $OS_VERSION)."
fi
command -v swift >/dev/null || die "Swift is missing. Install Xcode or run: xcode-select --install"
note "macOS $OS_VERSION, $(sysctl -n machdep.cpu.brand_string), $(swift --version 2>/dev/null | head -1 | sed 's/.*Apple Swift/Swift/; s/ (.*//')"

step "Ollama (local LLM for summaries)"
if ! command -v ollama >/dev/null; then
    command -v brew >/dev/null || die "Ollama is not installed and Homebrew is missing. Install Ollama from https://ollama.com/download"
    note "Installing Ollama with Homebrew…"
    brew install ollama
fi
if ! curl -fs -m 2 http://127.0.0.1:11434/api/version >/dev/null; then
    note "Starting the Ollama server…"
    (ollama serve >/dev/null 2>&1 &)
    for _ in $(seq 1 40); do
        curl -fs -m 2 http://127.0.0.1:11434/api/version >/dev/null && break
        sleep 0.25
    done
fi
curl -fs -m 2 http://127.0.0.1:11434/api/version >/dev/null || die "Could not reach Ollama at 127.0.0.1:11434. Start it with: ollama serve"
if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$SUMMARY_MODEL"; then
    note "Summary model $SUMMARY_MODEL is already installed."
else
    note "Pulling summary model $SUMMARY_MODEL…"
    ollama pull "$SUMMARY_MODEL"
fi

if [ "$WITH_BLACKHOLE" -eq 1 ]; then
    step "BlackHole 2ch (optional loopback driver)"
    if [ -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
        note "BlackHole 2ch is already installed."
    else
        command -v brew >/dev/null || die "Homebrew is required to install BlackHole: https://brew.sh"
        note "Installing blackhole-2ch (macOS will ask for your password)…"
        brew install --cask blackhole-2ch
        note "If BlackHole 2ch does not show up in Audio MIDI Setup, run: sudo killall coreaudiod   (or restart the Mac)"
    fi
fi

step "Building Earshot.app"
./scripts/build-app.sh

step "Downloading and compiling the speech models (one time, about 1 GB)"
note "Parakeet Ultra (speech-to-text), Silero VAD, Sortformer (speakers), LocalVQE (echo cancellation)"
"$(swift build -c release --show-bin-path)/earshot-cli" models

if [ "$INSTALL" -eq 1 ]; then
    step "Installing to /Applications"
    rm -rf /Applications/Earshot.app
    cp -R build/Earshot.app /Applications/Earshot.app
    note "Installed /Applications/Earshot.app"
fi

step "Done"
cat <<EOF
    Launch:   open $( [ "$INSTALL" -eq 1 ] && echo /Applications/Earshot.app || echo "$(pwd)/build/Earshot.app" )

    On the first recording macOS asks for two permissions — allow both:
      1. Microphone                  (your side of the call: "Me")
      2. System Audio Recording Only (everyone else: "Them")
    You can review them later in System Settings › Privacy & Security.

    Calls are saved to ~/Earshot/Calls/<date>-<title>/ (transcript.md, summary.md).
    See README.md for audio routing, the BlackHole fallback and troubleshooting.
EOF
