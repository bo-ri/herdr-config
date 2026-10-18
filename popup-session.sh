#!/bin/sh

set -eu

session_name="popup"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
popup_config="$script_dir/popup-config.toml"
herdr_bin=${HERDR_BIN_PATH:-$(command -v herdr)}
active_cwd=${HERDR_ACTIVE_PANE_CWD:-$PWD}

server_is_running() {
  "$herdr_bin" --session "$session_name" status server 2>/dev/null \
    | grep -q '^status: running$'
}

wait_for_server() {
  attempts=0
  while ! server_is_running; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 200 ]; then
      printf 'popup herdr session did not start\n' >&2
      exit 1
    fi
    sleep 0.05
  done
}

attach_session() {
  # The nested client needs a different keymap from the outer Herdr instance.
  # Reusing the outer popup bindings here would open another nested popup.
  export HERDR_CONFIG_PATH="$popup_config"
  exec "$herdr_bin" session attach "$session_name"
}

ensure_workspace() {
  popup_workspace_id=$(
    "$herdr_bin" --session "$session_name" workspace list \
      | jq -er '.result.workspaces[0].workspace_id // empty' \
      || true
  )
  if [ -z "$popup_workspace_id" ]; then
    popup_workspace_id=$(
      "$herdr_bin" --session "$session_name" workspace create \
        --cwd "$active_cwd" \
        --label "popup" \
        --focus \
        | jq -er '.result.workspace.workspace_id'
    )
  fi
  printf '%s\n' "$popup_workspace_id"
}

create_tool_tab() {
  label=$1
  tool_command=$2

  workspace_id=$(ensure_workspace)
  pane_id=$(
    "$herdr_bin" --session "$session_name" tab create \
      --workspace "$workspace_id" \
      --cwd "$active_cwd" \
      --label "$label" \
      --focus \
      | jq -er '.result.root_pane.pane_id'
  )

  # tab create starts an interactive login shell first. Sending input before
  # zsh has finished its startup files can make the command disappear.
  "$herdr_bin" --session "$session_name" pane wait-output \
    "$pane_id" \
    --match '➜' \
    --source recent-unwrapped \
    --lines 20 \
    --timeout 10000 \
    >/dev/null
  "$herdr_bin" --session "$session_name" pane run "$pane_id" "$tool_command"
}

run_action() {
  popup_action=$1
  case "$popup_action" in
    attach)
      ;;
    shell)
      create_tool_tab "shell" ':'
      ;;
    tig)
      if git -C "$active_cwd" rev-parse --git-dir >/dev/null 2>&1; then
        create_tool_tab "tig" 'exec tig'
      else
        create_tool_tab "tig" \
          'printf '\''tig: %s is not a Git repository\n'\'' "$PWD"'
      fi
      ;;
    git-switch)
      create_tool_tab "git-switch" 'exec git_switch_with_fzf'
      ;;
    git-description)
      create_tool_tab "git-description" 'exec git i'
      ;;
    lazydocker)
      create_tool_tab "lazydocker" 'exec lazydocker'
      ;;
    btop)
      create_tool_tab "btop" 'exec btop'
      ;;
    ekphos)
      create_tool_tab "ekphos" 'exec sh -lc '\''exec ekphos "$HOME/Documents/Obsidian Vault"'\'''
      ;;
    *)
      printf 'unknown popup action: %s\n' "$popup_action" >&2
      exit 2
      ;;
  esac
}

if [ "${1:-}" = "--wait-and-run" ]; then
  action=${2:-attach}
  active_cwd=${3:-$PWD}
  wait_for_server
  ensure_workspace >/dev/null
  run_action "$action"
  exit 0
fi

action=${1:-attach}

if server_is_running; then
  ensure_workspace >/dev/null
  run_action "$action"
elif [ "$action" != "attach" ]; then
  mkdir -p "$script_dir/sessions/$session_name"
  "$0" --wait-and-run "$action" "$active_cwd" \
    </dev/null >>"$script_dir/sessions/$session_name/bootstrap.log" 2>&1 &
fi

attach_session
