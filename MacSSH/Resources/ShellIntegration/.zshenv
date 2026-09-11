# 先保存 App 传入的运行时控制信息，再立即从 Shell 环境移除，避免子进程继承。
typeset -g _macssh_paste_highlight_requested="${MACSSH_PASTE_HIGHLIGHT_ENABLED:-1}"
typeset -g _macssh_paste_highlight_fifo="${MACSSH_PASTE_HIGHLIGHT_FIFO-}"
unset MACSSH_PASTE_HIGHLIGHT_ENABLED MACSSH_PASTE_HIGHLIGHT_FIFO

# 仅代理 .zshenv，并立即恢复原生目录：/etc/zshrc 设置 HISTFILE 时不得看到 App 路径。
# 用户文件在顶层读取一次，后续 .zprofile/.zshrc/.zlogin/.zlogout 均由 zsh 原生加载。
unset ZDOTDIR
[[ -r ${ZDOTDIR-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR-$HOME}/.zshenv"

if [[ -o interactive ]]; then
    # MacSSH 自有 OSC 7 cwd emitter（Phase 10D-B1）。
    #
    # 每个提示符把 PWD 以 `file://host/<percent-encoded path>` 上报给终端
    # （BEL 结束符）。编码与 Apple `/etc/zshrc_Apple_Terminal` 同源方案：
    # 在函数内局部 `LC_CTYPE=C` 强制 zsh 逐字节处理 PWD，safe bytes
    # （RFC3986 unreserved + `/`）原样保留，其余每个 UTF-8 byte 一律
    # `%HH`（大写十六进制）——覆盖空格、`%`、`?`、`#`、中日韩文与
    # Emoji，绝不只做 `${PWD// /%20}`。MacSSH 不设置 TERM_PROGRAM，
    # 不借用 Apple Terminal 的系统 cwd hook（任务书 10D-B1 §6）。
    _macssh_osc7_update_cwd() {
        local url_path=''
        {
            # 逐字节处理必须隔绝用户的 locale 设置（LC_ALL / LANG /
            # LC_CTYPE / LC_COLLATE），函数返回后由 local 自动恢复。
            local i ch hexch LC_CTYPE=C LC_COLLATE=C LC_ALL= LANG=
            for ((i = 1; i <= ${#PWD}; ++i)); do
                ch="$PWD[i]"
                if [[ "$ch" =~ [/._~A-Za-z0-9-] ]]; then
                    url_path+="$ch"
                else
                    printf -v hexch "%02X" "'$ch"
                    url_path+="%$hexch"
                fi
            done
        }
        # 统一 BEL (0x07) 结束符；本阶段不混用 ST（任务书 10D-B1 §5）。
        printf '\e]7;file://%s%s\a' "$HOST" "$url_path"
    }

    # 与粘贴高亮相同的 install-once 模式：在用户启动配置结束、首次
    # 提示符出现前注册 emitter，避免被用户 .zshrc 重建 precmd_functions
    # 时丢失；注册后自清理并立即上报一次当前目录（首个提示符即可用），
    # 不影响其余 precmd hook。
    _macssh_install_osc7_once() {
        typeset -ga precmd_functions
        precmd_functions+=(_macssh_osc7_update_cwd)
        precmd_functions=("${(@)precmd_functions:#_macssh_install_osc7_once}")
        unfunction _macssh_install_osc7_once
        _macssh_osc7_update_cwd
    }
    typeset -ga precmd_functions
    precmd_functions+=(_macssh_install_osc7_once)

    typeset -ga _macssh_saved_paste_highlight
    typeset -g _macssh_paste_highlight_state=""
    typeset -g _macssh_paste_highlight_fd=""

    # 只替换 paste:* 条目；其他 zle_highlight 样式保持原值。
    _macssh_apply_paste_highlight() {
        local requested="$1"
        typeset -ga zle_highlight

        if [[ "$requested" == "0" ]]; then
            if [[ "$_macssh_paste_highlight_state" != "disabled" ]]; then
                _macssh_saved_paste_highlight=("${(M@)zle_highlight:#paste:*}")
            fi
            zle_highlight=("${(@)zle_highlight:#paste:*}" 'paste:none')
            _macssh_paste_highlight_state="disabled"
        elif [[ "$requested" == "1" ]]; then
            if [[ "$_macssh_paste_highlight_state" == "disabled" ]]; then
                zle_highlight=(
                    "${(@)zle_highlight:#paste:*}"
                    "${(@)_macssh_saved_paste_highlight}"
                )
            fi
            _macssh_paste_highlight_state="enabled"
        fi
    }

    # 非阻塞排空 FIFO，只采用最后一个完整的 1/0 状态。
    _macssh_read_paste_highlight_requests() {
        local fd="$1"
        local value
        while IFS= read -r -t 0 -u "$fd" value; do
            if [[ "$value" == "0" || "$value" == "1" ]]; then
                _macssh_paste_highlight_requested="$value"
            fi
        done
    }

    # ZLE 监测到 FIFO 可读时执行：更新样式并立即重绘当前输入行。
    _macssh_paste_highlight_ready() {
        local fd="$1"
        local event="${2-}"
        if [[ -n "$event" ]]; then
            zle -F "$fd" 2>/dev/null
            return
        fi
        _macssh_read_paste_highlight_requests "$fd"
        _macssh_apply_paste_highlight "$_macssh_paste_highlight_requested"
        zle -R
    }

    # 等用户启动配置结束、首次提示符出现前，捕获用户原生 paste 样式并安装
    # FIFO handler；不发送终端命令、不模拟按键、不替换 bracketed-paste widget。
    _macssh_install_paste_highlight_once() {
        local control_directory
        if [[ -n "$_macssh_paste_highlight_fifo" &&
              -p "$_macssh_paste_highlight_fifo" &&
              -O "$_macssh_paste_highlight_fifo" ]]; then
            {
                exec {_macssh_paste_highlight_fd}<>"$_macssh_paste_highlight_fifo"
            } 2>/dev/null

            # 两端均已持有文件描述符后移除 App 自己创建的 FIFO 目录入口；
            # 通信继续有效，即使 App/测试宿主异常退出也不会留下临时文件。
            control_directory="${_macssh_paste_highlight_fifo:h}"
            if [[ "${_macssh_paste_highlight_fifo:t}" == "control.fifo" &&
                  "${control_directory:t}" == MacSSH-paste-highlight-* ]]; then
                /bin/rm -f -- "$_macssh_paste_highlight_fifo"
                /bin/rmdir -- "$control_directory" 2>/dev/null
            fi
        fi
        unset _macssh_paste_highlight_fifo

        if [[ -n "$_macssh_paste_highlight_fd" ]]; then
            _macssh_read_paste_highlight_requests "$_macssh_paste_highlight_fd"
            zle -F "$_macssh_paste_highlight_fd" _macssh_paste_highlight_ready 2>/dev/null
        fi
        _macssh_apply_paste_highlight "$_macssh_paste_highlight_requested"

        # 单次 hook 自行清理，不改变其余 precmd hook。
        precmd_functions=("${(@)precmd_functions:#_macssh_install_paste_highlight_once}")
        unfunction _macssh_install_paste_highlight_once
    }
    typeset -ga precmd_functions
    precmd_functions+=(_macssh_install_paste_highlight_once)
fi
