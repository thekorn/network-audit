# Sourced by the orb's login profile, not executed as a child shell.
_network_audit_activate() {
  local root
  root="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
  case "$PWD/" in
    "$root/"*) ;;
    *) return ;;
  esac
  [[ -z "${NETWORK_AUDIT_SKIP_ACTIVATION:-}" ]] || return 0
  [[ -z "${NETWORK_AUDIT_ACTIVATING:-}" ]] || return 0
  if [[ "${NETWORK_AUDIT_DEVENV:-}" == "$root" ]] && command -v flutter >/dev/null; then
    return 0
  fi
  # /etc/profile may reset PATH in an inherited login shell, even though the
  # devenv marker is still exported. Re-export the environment in that case.
  local -x NETWORK_AUDIT_ACTIVATING=1

  # Single-user Nix needs no daemon to survive an orb snapshot or resume.
  if [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.nix-profile/etc/profile.d/nix.sh" || return
  fi
  local devenv="$HOME/.local/share/network-audit/devenv/bin/devenv"
  if [[ ! -x "$devenv" ]]; then
    printf 'network-audit: run .agents/setup to install devenv.\n' >&2
    return 1
  fi
  local environment old_path="$PATH"
  environment="$(cd "$root" && "$devenv" --quiet print-dev-env)" || return
  # These Nix build variables must not leak into the caller. Local bindings
  # restore their previous values (or absence) when this function returns.
  # shellcheck disable=SC2034
  local TMP TMPDIR TEMP TEMPDIR NIX_BUILD_TOP
  eval "$environment" || return
  export PATH="$HOME/.local/share/network-audit/devenv/bin:$PATH:$old_path"
}

if _network_audit_activate; then
  unset -f _network_audit_activate
else
  unset -f _network_audit_activate
  return 1
fi
