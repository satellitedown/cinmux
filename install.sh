#!/usr/bin/env bash
# Cinmux installer for Arch Linux, Omarchy and macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/satellitedown/cinmux/master/install.sh | bash
#
# Installs any missing packages, builds the latest source, installs to ~/.local (and, on macOS, Cinmux.app to
# ~/Applications), and enables the OMP activity extension when OMP is set up. Re-run to update: tmux sessions
# survive; reopen the window for the new version.
#
# Environment overrides:
#   CINMUX_PREFIX    install prefix (default: ~/.local)
#   CINMUX_APP_DIR   macOS: where Cinmux.app goes (default: ~/Applications)
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
	wayland libxkbcommon pixman libvterm foot tmux git noto-fonts xdg-utils)

step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}

[[ $EUID -ne 0 ]] || fail "run as your normal user; sudo is only used to install missing packages"

fetch_source() {
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
}

# Links the OMP extension at $1 and sets omp_note.
link_omp() {
	local agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
	local link="$agent_dir/extensions/cinmux-activity.ts"
	omp_note=""
	if [[ -z ${CINMUX_NO_OMP:-} && -d $agent_dir ]]; then
		if [[ -e $link && ! -L $link ]]; then
			omp_note="OMP: left your existing $link untouched"
		else
			mkdir -p "$agent_dir/extensions"
			ln -sfn "$1" "$link"
			omp_note="OMP: agent status enabled; start new omp sessions to pick it up"
		fi
	fi
}

install_macos() {
	local app_dir="${CINMUX_APP_DIR:-$HOME/Applications}"
	local major
	major=$(sw_vers -productVersion | cut -d. -f1)
	((major >= 15)) || fail "Cinmux needs macOS 15 or newer"
	if ! xcode-select -p >/dev/null 2>&1; then
		xcode-select --install >/dev/null 2>&1 || true
		fail "install the Xcode Command Line Tools (a dialog just opened), then run this again"
	fi
	command -v swift >/dev/null || fail "swift is missing; reinstall the Xcode Command Line Tools"
	# A plain word list: macOS's bash 3.2 rejects empty arrays under `set -u`.
	local missing="" tool
	for tool in tmux git; do command -v "$tool" >/dev/null || missing="$missing $tool"; done
	if [[ -n $missing ]]; then
		command -v brew >/dev/null || fail "install$missing first (Homebrew: https://brew.sh)"
		step "Installing$missing"
		# shellcheck disable=SC2086 # split into package names
		brew install $missing
	fi

	fetch_source
	step "Building"
	local build="$CACHE/build-macos"
	"$src/macos/scripts/build-app.sh" "$build" >/dev/null

	step "Installing to $app_dir"
	mkdir -p "$app_dir" "$PREFIX/bin"
	local app="$app_dir/Cinmux.app"
	# Replace the bundle, never write into it: a running Cinmux keeps its open files.
	rm -rf "$app.new"
	cp -R "$build/Cinmux.app" "$app.new"
	rm -rf "$app"
	mv "$app.new" "$app"
	ln -sfn "$app/Contents/Helpers/cinmux" "$PREFIX/bin/cinmux"
	link_omp "$app/Contents/Resources/omp/cinmux-activity.ts"

	step "Cinmux is installed"
	echo "  Open Cinmux from Launchpad or Spotlight, or run: $PREFIX/bin/cinmux"
	[[ -z $omp_note ]] || echo "  $omp_note"
	case ":$PATH:" in
	*":$PREFIX/bin:"*) ;;
	*) echo "  Add $PREFIX/bin to your PATH to use the cinmux CLI from other terminals." ;;
	esac
	if pgrep -xq Cinmux; then
		echo "  Cinmux is running: quit it (⌘Q keeps sessions alive) and reopen it for the new version."
	fi
}

if [[ $(uname -s) == Darwin ]]; then
	install_macos
	exit 0
fi

command -v pacman >/dev/null || fail "this installer supports Arch Linux, Omarchy and macOS; see the README for other distributions"

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

fetch_source

# One build directory per source tree: CMake refuses to reuse a cache configured for another source.
build="$CACHE/build-$(printf '%s' "$src" | sha1sum | cut -c1-8)"
step "Building"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_TESTING=OFF >/dev/null
cmake --build "$build"

step "Installing to $PREFIX"
# Installing replaces files rather than writing into them, so this is safe while Cinmux is running.
cmake --install "$build" >/dev/null

link_omp "$PREFIX/share/cinmux/omp/cinmux-activity.ts"

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
