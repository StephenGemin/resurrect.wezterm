# Portable prompt-integration fixture for the run-wezterm skill.
#
# Reproduces the "restore replays the trailing prompt" class of bug WITHOUT
# depending on any developer's personal prompt tool (oh-my-posh, starship,
# powerlevel10k, ...) or dotfiles. It emits the standard OSC 133 semantic marks
# -- the shell-integration protocol WezTerm reads to delimit prompt vs. output
# -- plus a fixed, recognizable two-line prompt, so every dev on every OS gets a
# byte-identical layout to save, restore, and diff.
#
# Loaded via ZDOTDIR (see test-config.lua default_prog/ZDOTDIR), so it fully
# replaces ~/.zshrc for the test panes. Launched with `zsh -i -d`: -i so this rc
# is read, -d (NO_GLOBAL_RCS) so the global /etc/zsh* files can't perturb the
# layout across machines.

emulate -LR zsh
setopt PROMPT_SUBST
autoload -Uz add-zsh-hook

# OSC 133 marks (BEL-terminated). These are zero-width control sequences, not
# cell content -- whether they survive pane:get_lines_as_escapes() is exactly
# the question that decides if the trailing-prompt boundary is detectable at
# save time. A = prompt start, B = end of prompt / start of input,
# C = command start, D = command end. precmd runs just before each prompt, so it
# closes the previous command (D) and opens the next prompt (A).
_pi_precmd() { print -n '\e]133;D\a\e]133;A\a' }
_pi_preexec() { print -n '\e]133;C\a' }
add-zsh-hook precmd _pi_precmd
add-zsh-hook preexec _pi_preexec

# Fixed two-line prompt: a 'pi-path' info line + a 'pi> ' input line. Two rows so
# the prompt block matches a real multi-line prompt; static so save/restore diffs
# are deterministic and the duplication is countable (grep 'pi-path'). The B mark
# closes the prompt zone immediately before user input begins.
PROMPT=$'pi-path\n%{\e]133;B\a%}pi> '
