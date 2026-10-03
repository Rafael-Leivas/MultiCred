import Foundation

/// Shell hooks sourced from the user's rc files.
///
/// On every prompt each hook reads the small `generation` file; only when the
/// number changed does it source the env file. That makes terminals that are
/// already open follow a switch, at the cost of one tiny file read per prompt
/// (no fork in zsh). Sourcing a hook twice must not register it twice.
public enum ShellHookRenderer {
    /// Relative to `$HOME`, so the same hook works for any user.
    static let supportDirectoryExpression = "$HOME/Library/Application Support/MultiCred"

    public static func render(_ shell: ShellKind) -> String {
        switch shell {
        case .zsh: zsh
        case .bash: bash
        case .fish: fish
        }
    }

    static let zsh = """
    # MultiCred shell hook (zsh). Generated; do not edit.
    typeset -g _multicred_dir="\(supportDirectoryExpression)"
    _multicred_apply() {
      [[ -r "$_multicred_dir/generation" ]] || return 0
      local g="$(<"$_multicred_dir/generation")"
      [[ "$g" == "${_multicred_gen-}" ]] && return 0
      [[ -r "$_multicred_dir/env.sh" ]] && source "$_multicred_dir/env.sh"
      typeset -g _multicred_gen="$g"
    }
    _multicred_apply
    autoload -Uz add-zsh-hook && add-zsh-hook precmd _multicred_apply

    """

    // Works with bash 3.2 (macOS /bin/bash, string PROMPT_COMMAND) and bash 5.1+
    // (array PROMPT_COMMAND). Prepends so the env is ready for other prompt hooks.
    static let bash = """
    # MultiCred shell hook (bash). Generated; do not edit.
    _multicred_dir="\(supportDirectoryExpression)"
    _multicred_apply() {
      [ -r "$_multicred_dir/generation" ] || return 0
      local g=""
      IFS= read -r g < "$_multicred_dir/generation" || [ -n "$g" ] || return 0
      [ "$g" = "${_multicred_gen-}" ] && return 0
      [ -r "$_multicred_dir/env.sh" ] && . "$_multicred_dir/env.sh"
      _multicred_gen="$g"
    }
    _multicred_apply
    case ";${PROMPT_COMMAND[*]-};" in
      *"_multicred_apply"*) ;;
      *)
        if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
          PROMPT_COMMAND=("_multicred_apply" "${PROMPT_COMMAND[@]}")
        else
          PROMPT_COMMAND="_multicred_apply${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        fi
        ;;
    esac

    """

    static let fish = """
    # MultiCred shell hook (fish). Generated; do not edit.
    set -g __multicred_dir "\(supportDirectoryExpression)"
    function __multicred_apply --on-event fish_prompt
        test -r "$__multicred_dir/generation"; or return 0
        read -l g < "$__multicred_dir/generation"
        set -q __multicred_gen; and test "$g" = "$__multicred_gen"; and return 0
        test -r "$__multicred_dir/env.fish"; and source "$__multicred_dir/env.fish"
        set -g __multicred_gen $g
    end
    __multicred_apply

    """
}
