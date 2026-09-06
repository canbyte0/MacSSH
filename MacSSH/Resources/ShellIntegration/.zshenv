# 仅代理 .zshenv，并立即恢复原生目录：/etc/zshrc 设置 HISTFILE 时不得看到 App 路径。
# 用户文件在顶层读取一次，后续 .zprofile/.zshrc/.zlogin/.zlogout 均由 zsh 原生加载。
unset ZDOTDIR
[[ -r ${ZDOTDIR-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR-$HOME}/.zshenv"

if [[ -o interactive ]]; then
    # 等用户启动配置结束、首次提示符出现前应用偏好；不发送命令或模拟按键。
    _macssh_disable_paste_highlight_once() {
        typeset -ga zle_highlight
        zle_highlight=("${(@)zle_highlight:#paste:*}" 'paste:none')
        # 单次 hook 自行清理，不改变其余 precmd hook 或任何 bracketed paste widget。
        precmd_functions=("${(@)precmd_functions:#_macssh_disable_paste_highlight_once}")
        unfunction _macssh_disable_paste_highlight_once
    }
    typeset -ga precmd_functions
    precmd_functions+=(_macssh_disable_paste_highlight_once)
fi
