#!/usr/bin/env bash
# Cinmux installer for Arch Linux and Omarchy:
#
#   curl -fsSL https://raw.githubusercontent.com/satellitedown/cinmux/master/install.sh | bash
#
# Installs any missing packages, builds the latest source, installs to ~/.local, and enables the OMP activity
# extension when OMP is set up. Re-run to update: tmux sessions survive; reopen the window for the new version.
#
# Environment overrides:
#   CINMUX_PREFIX    install prefix (default: ~/.local)
#   CINMUX_REF       branch or tag to build (default: master)
#   CINMUX_SRC       build this existing checkout instead of downloading
#   CINMUX_NO_OMP=1  do not link the OMP activity extension
set -euo pipefail

REPO_URL="https://github.com/satellitedown/cinmux.git"
REF="${CINMUX_REF:-master}"
PREFIX="${CINMUX_PREFIX:-$HOME/.local}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/cinmux"
# Keep in sync with the README's dependency list.
PACKAGES=(gcc cmake ninja pkgconf qt6-base qt6-declarative qt6-wayland qt6-svg icu tomlplusplus wlroots0.20
	wayland libxkbcommon pixman foot tmux git noto-fonts xdg-utils)

step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}

[[ $EUID -ne 0 ]] || fail "run as your normal user; sudo is only used to install missing packages"
command -v pacman >/dev/null || fail "this installer supports Arch Linux and Omarchy; see the README for other distributions"

# `pacman -T` prints the packages that are not installed (and exits non-zero when there are any).
mapfile -t missing < <(pacman -T "${PACKAGES[@]}" || true)
if ((${#missing[@]})); then
	step "Installing missing packages: ${missing[*]}"
	if command -v omarchy >/dev/null; then
		omarchy pkg add "${missing[@]}"
	else
		sudo pacman -S --needed "${missing[@]}"
	fi
fi

if [[ -n ${CINMUX_SRC:-} ]]; then
	src=$(cd "$CINMUX_SRC" && pwd)
	step "Using local checkout $src"
else
	src="$CACHE/src"
	if [[ -d $src/.git ]]; then
		step "Updating Cinmux ($REF)"
		git -C "$src" fetch --quiet --depth 1 origin "$REF"
		git -C "$src" checkout --quiet --force FETCH_HEAD
	else
		step "Downloading Cinmux ($REF)"
		rm -rf "$src"
		git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$src"
	fi
fi

# One build directory per source tree: CMake refuses to reuse a cache configured for another source.
build="$CACHE/build-$(printf '%s' "$src" | sha1sum | cut -c1-8)"
step "Building"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_TESTING=OFF >/dev/null
cmake --build "$build"

step "Installing to $PREFIX"
# Installing replaces files rather than writing into them, so this is safe while Cinmux is running.
cmake --install "$build" >/dev/null

agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
link="$agent_dir/extensions/cinmux-activity.ts"
omp_note=""
if [[ -z ${CINMUX_NO_OMP:-} && -d $agent_dir ]]; then
	if [[ -e $link && ! -L $link ]]; then
		omp_note="OMP: left your existing $link untouched"
	else
		mkdir -p "$agent_dir/extensions"
		ln -sfn "$PREFIX/share/cinmux/omp/cinmux-activity.ts" "$link"
		omp_note="OMP: agent status enabled; start new omp sessions to pick it up"
	fi
fi

step "Cinmux is installed"
echo "  Launch it from your app launcher, or run: $PREFIX/bin/cinmux"
[[ -z $omp_note ]] || echo "  $omp_note"
case ":$PATH:" in
*":$PREFIX/bin:"*) ;;
*) echo "  Add $PREFIX/bin to your PATH to use the cinmux CLI from other terminals." ;;
esac
if pgrep -x cinmux >/dev/null; then
	echo "  Cinmux is running: quit it (Ctrl+Shift+Q keeps sessions alive) and reopen it for the new version."
fi
