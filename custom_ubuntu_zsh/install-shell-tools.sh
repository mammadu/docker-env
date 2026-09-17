#!/usr/bin/env bash
# install-shell-tools.sh: zsh + oh-my-zsh + plugins + fzf + tldr for Debian/Ubuntu containers.
#
# Usage (as root):  bash install-shell-tools.sh [user ...]
#   No args: sets up root, plus the UID 1000 user if one exists
#   (e.g. "ubuntu" on ubuntu:24.04, "vscode" on devcontainer base images).
#
# Environment overrides (pin these for reproducible builds):
#   FZF_VERSION       fzf release, e.g. 0.74.4               (default: latest)
#   TEALDEER_VERSION  tealdeer (tldr) release, e.g. 1.9.0    (default: latest)
#   OMZ_REF           oh-my-zsh branch or tag                (default: master)
#   FSH_REF           fast-syntax-highlighting branch or tag (default: master)
#   ZAS_REF           zsh-autosuggestions branch or tag      (default: master)
#   UNMINIMIZE        1 = restore ALL man pages on minimized Ubuntu images (slower, bigger image)
#                     0 = only keep man pages for packages installed by this script
#   ENABLE_SUDO       1 = install sudo and give each configured non-root user passwordless sudo
#                     0 = don't touch sudo
set -euo pipefail

FZF_VERSION="${FZF_VERSION:-latest}"
TEALDEER_VERSION="${TEALDEER_VERSION:-latest}"
OMZ_REF="${OMZ_REF:-master}"
FSH_REF="${FSH_REF:-master}"
ZAS_REF="${ZAS_REF:-master}"
UNMINIMIZE="${UNMINIMIZE:-1}"
ENABLE_SUDO="${ENABLE_SUDO:-1}"
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (or with sudo)." >&2
  exit 1
fi
cd /

# ------------------------------------------------------------------ helpers
home_of() { getent passwd "$1" | cut -d: -f6; }
as_user() { local u="$1"; shift; runuser -u "$u" -- env HOME="$(home_of "$u")" "$@"; }

# Resolve "latest" via GitHub's redirect rather than the API (avoids rate limits).
resolve_tag() { # <owner/repo> <version|latest>
  if [ "$2" = latest ]; then
    curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's|.*/tag/||'
  else
    echo "v${2#v}"
  fi
}

clone() { # <user> <owner/repo> <ref> <dest>   (skips if already cloned)
  if [ ! -d "$4/.git" ]; then
    as_user "$1" git clone --quiet --depth 1 --branch "$3" "https://github.com/$2.git" "$4"
  fi
}

case "$(dpkg --print-architecture)" in
  amd64) FZF_ARCH=amd64; TLDR_ARCH=x86_64 ;;
  arm64) FZF_ARCH=arm64; TLDR_ARCH=aarch64 ;;
  *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

# ------------------------------------------------------------------ man pages
# Ubuntu Docker images are "minimized": man pages are stripped and `man` is a stub.
restore_man_pages() {
  local bin excludes
  # Ubuntu calls this file "excludes"; Debian slim images use other names.
  excludes="$(grep -rls '^path-exclude.*share/man' /etc/dpkg/dpkg.cfg.d/ 2>/dev/null || true)"
  [ -n "$excludes" ] || return 0   # not a minimized image

  if [ "$UNMINIMIZE" = 1 ]; then
    apt-get install -y unminimize >/dev/null 2>&1 || true   # separate package on 24.04+
    for bin in /usr/bin/unminimize /usr/local/sbin/unminimize; do
      if [ -x "$bin" ]; then
        log "Restoring man pages for all packages with unminimize (takes a few minutes)"
        { yes || true; } | "$bin"
        break
      fi
    done
  fi

  # Fallback (or UNMINIMIZE=0): keep man pages for packages installed from here on.
  excludes="$(grep -rls '^path-exclude.*share/man' /etc/dpkg/dpkg.cfg.d/ 2>/dev/null || true)"
  if [ -n "$excludes" ]; then
    log "Allowing man pages for newly installed packages"
    echo "$excludes" | xargs sed -i -e '\|/usr/share/man|d' -e '\|/usr/share/groff|d'
  fi
  if [ "$(dpkg-divert --truename /usr/bin/man)" = /usr/bin/man.REAL ]; then
    rm -f /usr/bin/man
    dpkg-divert --quiet --remove --rename /usr/bin/man
  fi
}

log "Updating apt"
apt-get update
restore_man_pages

log "Installing packages"
packages=(ca-certificates curl git zsh less man-db manpages)
if [ "$ENABLE_SUDO" = 1 ]; then packages+=(sudo); fi
apt-get install -y --no-install-recommends "${packages[@]}"

# ------------------------------------------------------------------ fzf
tag="$(resolve_tag junegunn/fzf "$FZF_VERSION")"
log "Installing fzf $tag"
curl -fsSL "https://github.com/junegunn/fzf/releases/download/${tag}/fzf-${tag#v}-linux_${FZF_ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin fzf

# ------------------------------------------------------------------ tldr (tealdeer)
tag="$(resolve_tag tealdeer-rs/tealdeer "$TEALDEER_VERSION")"
log "Installing tldr (tealdeer $tag)"
base="https://github.com/tealdeer-rs/tealdeer/releases/download/${tag}"
curl -fsSL -o /usr/local/bin/tldr "$base/tealdeer-linux-${TLDR_ARCH}-musl"
chmod 755 /usr/local/bin/tldr
mkdir -p /usr/local/share/zsh/site-functions
curl -fsSL -o /usr/local/share/zsh/site-functions/_tldr "$base/completions_zsh" \
  || echo "(no zsh completion in this tealdeer release, skipping)"

# ------------------------------------------------------------------ per-user setup
setup_user() {
  local user="$1" home
  home="$(home_of "$user")"
  if [ -z "$home" ]; then
    echo "No such user: $user" >&2
    return 1
  fi
  log "Configuring zsh for $user ($home)"
  [ -d "$home" ] || install -d -o "$user" -g "$(id -gn "$user")" "$home"

  local omz="$home/.oh-my-zsh"
  clone "$user" ohmyzsh/ohmyzsh "$OMZ_REF" "$omz"
  clone "$user" zdharma-continuum/fast-syntax-highlighting "$FSH_REF" "$omz/custom/plugins/fast-syntax-highlighting"
  clone "$user" zsh-users/zsh-autosuggestions "$ZAS_REF" "$omz/custom/plugins/zsh-autosuggestions"

  local rc="$home/.zshrc"
  if [ -f "$rc" ] && ! grep -q 'managed by install-shell-tools.sh' "$rc"; then
    cp "$rc" "$rc.pre-install-shell-tools"
  fi
  cat > "$rc" <<'EOF'
# managed by install-shell-tools.sh (put personal tweaks in ~/.zshrc.local)
export LANG="${LANG:-C.UTF-8}"
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
zstyle ':omz:update' mode disabled   # no update prompts inside containers

plugins=(
  git                       # git aliases: gst, gco, gp, ...
  colored-man-pages
  man                       # press Esc, then type "man": man page for the current command
  zsh-autosuggestions
  fast-syntax-highlighting  # keep last
)

source "$ZSH/oh-my-zsh.sh"

# fzf: Ctrl-T files, Ctrl-R history, Alt-C cd, **<Tab> fuzzy completion
source <(fzf --zsh)

[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
EOF
  chown "$user:" "$rc"

  usermod --shell "$(command -v zsh)" "$user"

  if [ "$ENABLE_SUDO" = 1 ] && [ "$user" != root ]; then
    # sudo ignores files containing "." or "~", so sanitise the name.
    local sudoers="/etc/sudoers.d/90-$(printf '%s' "$user" | tr -c '[:alnum:]_-' '_')"
    echo "$user ALL=(ALL) NOPASSWD:ALL" > "$sudoers"
    chmod 0440 "$sudoers"
    visudo -cqf "$sudoers" || { echo "Invalid sudoers file for $user" >&2; rm -f "$sudoers"; return 1; }
  fi
  if ! as_user "$user" tldr --update >/dev/null 2>&1; then
    # Behind a TLS-inspecting proxy, tealdeer's bundled CA list fails; use the system store.
    as_user "$user" mkdir -p "$home/.config/tealdeer"
    printf '[updates]\ntls_backend = "rustls-with-native-roots"\n' | as_user "$user" tee "$home/.config/tealdeer/config.toml" >/dev/null
    as_user "$user" tldr --update >/dev/null || echo "(tldr cache update failed; run 'tldr --update' later)"
  fi
}

users=("$@")
if [ ${#users[@]} -eq 0 ]; then
  users=(root)
  uid1000="$(getent passwd 1000 | cut -d: -f1 || true)"
  if [ -n "$uid1000" ]; then users+=("$uid1000"); fi
fi
for u in "${users[@]}"; do
  setup_user "$u"
done

apt-get clean
rm -rf /var/lib/apt/lists/*
log "Done. zsh is now the login shell for: ${users[*]}"