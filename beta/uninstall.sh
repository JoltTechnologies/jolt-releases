#!/usr/bin/env bash
set -euo pipefail
umask 077
install_dir="$HOME/.local/bin"; purge=false
existing="$(command -v jolt || true)"
case "$existing" in "$HOME"/*/jolt) [[ ! -f "${existing%/jolt}/.jolt-install.json" ]] || install_dir="${existing%/jolt}";; esac
while [[ $# -gt 0 ]]; do case "$1" in --dir) [[ $# -ge 2 ]] || exit 1; install_dir="$2"; shift 2;; --purge) purge=true; shift;; *) echo 'Usage: bash uninstall.sh [--dir DIRECTORY] [--purge]' >&2; exit 1;; esac; done
[[ "$install_dir" == /* && "$install_dir" != *$'\n'* && "$install_dir" != *$'\r'* && "$install_dir" != *'\'* ]] || exit 1
[[ -d "$install_dir" ]] || { echo 'Jolt is not installed here.'; exit 0; }
install_dir="$(cd "$install_dir" && pwd -P)"; target="$install_dir/jolt"; receipt="$install_dir/.jolt-install.json"
[[ ! -L "$target" && ! -L "$receipt" && -f "$receipt" && -f "$target" ]] || { echo 'No managed Jolt installation; nothing was removed.' >&2; exit 1; }
grep -Eq '^  "schema": 1,$' "$receipt" && grep -Eq '^  "binary": "jolt",$' "$receipt" || { echo 'Invalid installation receipt.' >&2; exit 1; }
sha="$(sed -n 's/^  "sha256": "\([a-f0-9]\{64\}\)"[,]\{0,1\}$/\1/p' "$receipt")"
if command -v sha256sum >/dev/null; then actual="$(sha256sum "$target" | cut -d ' ' -f 1)"; else actual="$(shasum -a 256 "$target" | cut -d ' ' -f 1)"; fi
[[ "$sha" == "$actual" ]] || { echo 'Managed binary changed; inspect it before removing manually.' >&2; exit 1; }
lock="$install_dir/.jolt-update.lock"; (set -o noclobber; : > "$lock") 2>/dev/null || { echo 'An update is running; try later.' >&2; exit 1; }
trap 'rm -f -- "$lock"' EXIT
rm -f -- "$target" "$receipt"
for prefix in .jolt-previous- .jolt-running- .jolt-update- .jolt-receipt-; do
 for file in "$install_dir/$prefix"*; do [[ ! -f "$file" && ! -L "$file" ]] || rm -f -- "$file"; done
done
begin="# >>> JoltCLI ($install_dir) >>>"; end="# <<< JoltCLI ($install_dir) <<<"
for profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.zprofile" "$HOME/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc"; do
 [[ -f "$profile" && ! -L "$profile" ]] || continue
 if grep -Fqx -- "$begin" "$profile"; then
  temporary="$(mktemp "${profile}.jolt-XXXXXXXX")"
  cp -p "$profile" "$temporary"
  awk -v begin="$begin" -v end="$end" '$0 == begin {skip=1; next} $0 == end {skip=0; next} !skip {print}' "$profile" > "$temporary"
  mv -f -- "$temporary" "$profile"
 fi
done
if $purge; then
 case "$(uname -s)" in Darwin) config="$HOME/Library/Application Support/jolt";; Linux) config="${XDG_CONFIG_HOME:-$HOME/.config}/jolt";; *) exit 1;; esac
 [[ "$config" == /* && "$config" != /jolt ]] || exit 1
 rm -rf -- "$config"
fi
echo 'Jolt uninstalled. Configuration is preserved unless --purge was selected. Server-side machine access is not revoked; use JoltCode device settings.'
