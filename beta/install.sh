#!/bin/sh
# POSIX entry point supports curl ... | sh. Bash is included on supported macOS
# and common Linux distributions. The complete function is parsed before running.
jolt_install() {
 command -v bash >/dev/null 2>&1 || { echo 'JoltCLI installer requires Bash.' >&2; return 1; }
 bash -s -- "$@" <<'JOLT_INSTALLER_BODY'
# Versioned installer: hashes are pinned at release preparation, never fetched
# from an unsigned checksum endpoint. Inspect this downloaded script before use.
set -euo pipefail
umask 077
version='0.1.0-beta.6'
repository='JoltTechnologies/jolt-releases'
public_key='s8jxgpAzaPAgu0EVjzyokZCtDmjAwQ4WoFubIPXj4ks=' # Trust anchor, never fetched from the release server.
install_dir="${HOME}/.local/bin"
# Prefer an existing user-owned PATH directory, never a system directory.
if [[ -n "${HOME:-}" && "$HOME" == /* ]]; then
 old_ifs="$IFS"; IFS=:
 for candidate in $PATH; do
  case "$candidate" in "$HOME"/*)
   if [[ -d "$candidate" && -w "$candidate" && -O "$candidate" && ! -L "$candidate" ]]; then install_dir="$candidate"; break; fi;;
  esac
 done
 IFS="$old_ifs"
fi
add_path=true
while [[ $# -gt 0 ]]; do
 case "$1" in
  --dir) [[ $# -ge 2 ]] || { echo 'Missing --dir value' >&2; exit 1; }; install_dir="$2"; shift 2;;
  --no-path) add_path=false; shift;;
  *) echo 'Usage: bash install.sh [--dir DIRECTORY] [--no-path]' >&2; exit 1;;
 esac
done
case "$install_dir" in /*) ;; *) echo 'Installation directory must be absolute.' >&2; exit 1;; esac
[[ "$install_dir" != *$'\n'* && "$install_dir" != *$'\r'* && "$install_dir" != *'\'* ]] || { echo 'Unsupported installation directory.' >&2; exit 1; }
case "$(uname -s)" in Linux) os=linux;; Darwin) os=darwin;; *) echo 'Use the PowerShell installer on Windows.' >&2; exit 1;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) echo 'Unsupported CPU architecture.' >&2; exit 1;; esac
# Rosetta reports x86_64 even on Apple Silicon; prefer the native binary.
if [[ "$os" == darwin && "$arch" == amd64 ]] && [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then arch=arm64; fi
case "$os-$arch" in
 linux-amd64) sha='3fb8aa324dd02602414d74c6b912b9d653cc9d620c1762b65f5256e32c6421ac';;
 linux-arm64) sha='380ab50f6295aca79b74ec6abcb450d5c75efbabf95d2ac006345c5d4ff9f3f0';;
 darwin-amd64) sha='1de979a8fbc8d3b883471c13acaf66967446e2e1bf56ecd2117fd584e7761c93';;
 darwin-arm64) sha='f41adb4cbfa14d9eb52cc68c958d90c133678f40db4871149e36891364ff9c2d';;
esac
hash_file(){ if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1; elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d ' ' -f 1; else echo 'Install an OS SHA-256 utility (sha256sum or shasum).' >&2; return 1; fi; }
command -v curl >/dev/null || { echo 'curl is required.' >&2; exit 1; }
mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd -P)"
target="$install_dir/jolt"
receipt="$install_dir/.jolt-install.json"
[[ ! -L "$target" && ! -L "$receipt" ]] || { echo 'Refusing a symlink installation.' >&2; exit 1; }
if [[ -e "$target" ]]; then
 [[ -f "$target" && -f "$receipt" ]] || { echo 'Refusing to overwrite an unmanaged jolt. Choose another --dir.' >&2; exit 1; }
 grep -Eq '^  "schema": 1,$' "$receipt" && grep -Eq '^  "binary": "jolt",$' "$receipt" || { echo 'Invalid installation receipt.' >&2; exit 1; }
 previous_sha="$(sed -n 's/^  "sha256": "\([a-f0-9]\{64\}\)"[,]\{0,1\}$/\1/p' "$receipt")"
 [[ "$(hash_file "$target")" == "$previous_sha" ]] || { echo 'Existing managed binary changed; refusing replacement.' >&2; exit 1; }
fi
lock="$install_dir/.jolt-update.lock"
(set -o noclobber; : > "$lock") 2>/dev/null || { echo 'An installation/update is already running.' >&2; exit 1; }
stage=''; receipt_stage=''; backup=''; manifest_stage=''
cleanup(){ [[ -z "$manifest_stage" ]] || rm -f -- "$manifest_stage"; [[ -z "$stage" ]] || rm -f -- "$stage"; [[ -z "$receipt_stage" ]] || rm -f -- "$receipt_stage"; rm -f -- "$lock"; }
trap cleanup EXIT
stage="$(mktemp "$install_dir/.jolt-update-XXXXXXXX")"
curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --max-filesize 104857600 "https://github.com/$repository/releases/download/v$version/jolt-$os-$arch" -o "$stage"
[[ "$(hash_file "$stage")" == "$sha" ]] || { echo 'Artifact checksum mismatch. Nothing was installed.' >&2; exit 1; }
manifest_stage="$(mktemp "$install_dir/.jolt-manifest-XXXXXXXX")"
curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --max-filesize 1048576 "https://github.com/$repository/releases/download/v$version/manifest.json" -o "$manifest_stage"
# Bootstrap is already authenticated by the trusted installer's embedded hash.
# It supplies portable Ed25519 verification without OpenSSL/PowerShell dependencies.
chmod 755 "$stage"
JOLT_NO_UPDATE_CHECK=1 "$stage" verify-release --manifest "$manifest_stage" --expected-key "$public_key"
[[ "$(JOLT_NO_UPDATE_CHECK=1 "$stage" version)" == "jolt version $version" ]] || { echo 'Wrong executable/version. Nothing was installed.' >&2; exit 1; }
receipt_stage="$(mktemp "$install_dir/.jolt-receipt-XXXXXXXX")"
printf '{\n  "schema": 1,\n  "binary": "jolt",\n  "version": "%s",\n  "sha256": "%s",\n  "ownedPathEntry": false\n}\n' "$version" "$sha" > "$receipt_stage"
if [[ -f "$target" ]]; then backup="$(mktemp "$install_dir/.jolt-previous-XXXXXXXX")"; cp -p "$target" "$backup"; fi
mv -f -- "$stage" "$target"; stage=''
if ! mv -f -- "$receipt_stage" "$receipt"; then
 if [[ -n "$backup" ]]; then mv -f -- "$backup" "$target"; else rm -f -- "$target"; fi
 echo 'Could not save installation receipt; replacement rolled back.' >&2; exit 1
fi
receipt_stage=''
# Only add PATH when absent. Bash interactive terminals read .bashrc;
# login shells read the first existing login file. Zsh uses .zshrc/.zprofile.
old_ifs="$IFS"; IFS=:
for candidate in $PATH; do
 if [[ "$candidate" == /* && -d "$candidate" && "$candidate" -ef "$install_dir" ]]; then add_path=false; break; fi
done
IFS="$old_ifs"
if $add_path; then
 profiles=("$HOME/.bashrc")
 if [[ -f "$HOME/.bash_profile" ]]; then profiles+=("$HOME/.bash_profile");
 elif [[ -f "$HOME/.bash_login" ]]; then profiles+=("$HOME/.bash_login");
 else profiles+=("$HOME/.profile"); fi
 if [[ "${SHELL:-}" == */zsh ]]; then
  zhome="${ZDOTDIR:-$HOME}"
  [[ "$zhome" == /* && -d "$zhome" && -O "$zhome" ]] || { echo 'Cannot safely configure Zsh. Use the printed PATH command.' >&2; zhome="$HOME"; }
  profiles=("$zhome/.zshrc" "$zhome/.zprofile")
 fi
 begin="# >>> JoltCLI ($install_dir) >>>"; end="# <<< JoltCLI ($install_dir) <<<"
 for profile in "${profiles[@]}"; do
  if [[ -L "$profile" || ( -e "$profile" && ( ! -f "$profile" || ! -O "$profile" ) ) ]]; then echo "Skipped unsafe shell profile: $profile. Use the printed PATH command." >&2; continue; fi
  if [[ ! -e "$profile" ]] || ! grep -Fqx -- "$begin" "$profile"; then
   if printf '\n%s\nexport PATH=%q:"$PATH"\n%s\n' "$begin" "$install_dir" "$end" >> "$profile"; then
    printf 'Configured PATH in %s (open a new terminal).\n' "$profile"
   else echo 'Could not update shell profile; use the printed PATH command.' >&2; fi
  fi
 done
fi
printf '\nJoltCLI installed successfully!\nVersion: v%s\nExecutable: %s\n\nFor this shell: export PATH=%q:"$PATH"\n\nNext steps:\n1. Run: jolt --version\n2. Enter your project directory and run: jolt connect\n3. Sign in to JoltCode and approve your machine.\n4. Open JoltCode Desktop or https://joltcode.pages.dev\n5. Select your connected workspace.\n' "$version" "$target" "$install_dir"
JOLT_INSTALLER_BODY
}
jolt_install "$@"
