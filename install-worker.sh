#!/bin/sh
# Installs studio-worker, which makes this machine a Studio worker: Studio (on your Mac) can start agent
# sessions here and its AIs can hand work to them. Linux or macOS, amd64 or arm64.
#   curl -fsSL https://raw.githubusercontent.com/fiberevm/studio/main/install-worker.sh | sh
set -eu

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "studio-worker runs on Linux and macOS." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

dest="${STUDIO_WORKER_DIR:-$HOME/.local/bin}"
mkdir -p "$dest"
url="https://github.com/fiberevm/studio/releases/latest/download/studio-worker-$os-$arch"
echo "Downloading $url"
curl -fsSL "$url" -o "$dest/studio-worker.tmp"
chmod +x "$dest/studio-worker.tmp"
mv -f "$dest/studio-worker.tmp" "$dest/studio-worker"
echo "Installed $dest/studio-worker ($("$dest/studio-worker" version))"

case ":$PATH:" in *":$dest:"*) ;; *) echo "Add $dest to your PATH, e.g.: echo 'export PATH=\"$dest:\$PATH\"' >> ~/.bashrc" ;; esac
command -v tmux >/dev/null 2>&1 || echo "studio-worker needs tmux: install it (sudo apt install tmux, sudo dnf install tmux, brew install tmux)."
for a in claude codex agy; do command -v "$a" >/dev/null 2>&1 && have="${have:-}$a " ; done
echo "Agent CLIs found: ${have:-none yet (install Claude Code, Codex or agy, and log in)}"
echo
echo "Next:"
if [ "$os" = linux ] && command -v systemctl >/dev/null 2>&1; then
  echo "  $dest/studio-worker install-service   # runs it in the background, prints the pairing link"
else
  echo "  $dest/studio-worker serve             # prints the pairing link"
fi
echo "Then in Studio: Settings → Workers → paste the link."
