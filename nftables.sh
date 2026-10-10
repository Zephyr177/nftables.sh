#!/usr/bin/env bash
# =============================================================================
#  nftables 端口转发管理脚本  ——  Debian / Ubuntu
# =============================================================================
#  功能:
#    1) 启动时自动检测 nftables 是否安装、服务是否运行;
#       未安装 / 未启动时提示是否由本脚本自动安装 (apt-get) / 启动 (systemctl)
#    2) 添加端口转发: 支持单个端口 (8080) 与批量端口范围 (53000-54000),
#       协议可选 TCP / UDP / TCP+UDP, 目标端口可自定义或保持原端口
#    3) 菜单查看 / 删除 / 清空当前转发规则
#    4) 菜单开启 / 关闭 nftables 开机自启 (systemctl enable/disable)
#
#  实现说明:
#    * 转发规则放在独立表 ip pf 中, 与 Docker 使用的 ip nat 表互不干扰
#    * 添加/删除规则实时生效, 并自动持久化到 CONF_FILE;
#      CONF_FILE 由 MAIN_CONF 通过 include 引入, 开机由 nftables.service 恢复
#    * postrouting 链自动维护 "ct status dnat masquerade", 保证被转发流量
#      的回程经过本机 (同网段 / 跨网段均可正常转发)
#    * 仅处理 IPv4
#
#  用法:
#    sudo bash nftables.sh
# =============================================================================

set -u -o pipefail

# ------------------------------- 可覆盖配置 ----------------------------------
TABLE_FAMILY="${NFT_TABLE_FAMILY:-ip}"                          # 地址族
TABLE_NAME="${NFT_TABLE_NAME:-pf}"                              # 专用表名
CONF_FILE="${NFT_PF_CONF:-/etc/nftables.d/portforward.nft}"     # 持久化规则文件
MAIN_CONF="${NFT_MAIN_CONF:-/etc/nftables.conf}"                # 服务主配置文件
SERVICE="${NFT_SERVICE:-nftables}"                              # systemd 单元名
SYSTEMD_RUNTIME_DIR="${NFT_SYSTEMD_DIR:-/run/systemd/system}"   # systemd 运行标志
CONF_DIR="$(dirname "$CONF_FILE")"

# 匹配转发规则 (带 handle, 用于解析)
RE_FWD_RULE='^[[:space:]]+(tcp|udp)[[:space:]]+dport[[:space:]]+[0-9]+(-[0-9]+)?[[:space:]]+dnat[[:space:]]+to[[:space:]]'
RE_FWD_PARSE='^[[:space:]]+(tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+(-[0-9]+)?)[[:space:]]+dnat[[:space:]]+to[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:([0-9]+(-[0-9]+)?))?.*# handle ([0-9]+)'

# ------------------------------- 输出与交互 ----------------------------------
if [[ -t 1 ]]; then
    C_RST=$'\033[0m'; C_BLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
    C_RST=''; C_BLD=''; C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''
fi

info()  { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
title() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_RST"; }
hr()    { printf '%s\n' "------------------------------------------------------------------------"; }

# read_line <变量名> [提示文字]  —— 读取一行并去掉首尾空白, EOF 时返回 1
read_line() {
    local __var="$1" __prompt="${2:-}" __val
    [[ -n $__prompt ]] && printf '%s' "$__prompt"
    IFS= read -r "$__var" || return 1
    __val="${!__var}"
    __val="${__val#"${__val%%[![:space:]]*}"}"
    __val="${__val%"${__val##*[![:space:]]}"}"
    printf -v "$__var" '%s' "$__val"
    return 0
}

confirm() {     # 询问 y/N, 默认 No
    local a
    read_line a "$1 [y/N]: " || return 1
    case $a in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

press_enter() {
    printf '\n按回车键返回菜单...'
    IFS= read -r _ || true
    printf '\n'
}

# pad_disp <字符串> <显示宽度> —— 按显示宽度右侧补空格 (CJK 字符按 2 列计)
pad_disp() {
    local s="$1" width="$2" w=0 i ch
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        if [[ $ch == [!\ -~] ]]; then w=$((w + 2)); else w=$((w + 1)); fi
    done
    printf '%s' "$s"
    if (( w < width )); then printf '%*s' "$((width - w))" ''; fi
}

# ------------------------------- 环境检测 ------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }
nft_installed()  { command_exists nft; }
has_systemd()    { command_exists systemctl && [[ -d $SYSTEMD_RUNTIME_DIR ]]; }

svc_unit_exists() {
    has_systemd || return 1
    local out
    out="$(systemctl list-unit-files --no-legend "$SERVICE.service" 2>/dev/null)"
    [[ $out == *"${SERVICE}.service"* ]]
}

svc_active_state() {
    has_systemd || { printf 'unknown'; return 0; }
    systemctl is-active "$SERVICE" 2>/dev/null || true
}

svc_enabled_state() {
    has_systemd || { printf 'unknown'; return 0; }
    systemctl is-enabled "$SERVICE" 2>/dev/null || true
}

enabled_text() {
    case "$(svc_enabled_state)" in
        enabled)  printf '已启用' ;;
        disabled) printf '已禁用' ;;
        static)   printf '静态(随其它单元启动)' ;;
        masked)   printf '已屏蔽(masked)' ;;
        '')       printf '未知' ;;
        *)        printf '%s' "$(svc_enabled_state)" ;;
    esac
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    if command_exists sudo; then
        info "当前非 root 用户, 使用 sudo 重新运行..."
        exec sudo -- "$0" "$@"
    fi
    err "本脚本需要 root 权限, 请使用: sudo bash $0"
    exit 1
}

# ------------------------------- nft 基础操作 --------------------------------
pf_table_exists() { nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; }
pf_chain_exists() { nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$1" >/dev/null 2>&1; }

# 注意: 不要写成 "nft ... | grep -q", grep -q 提前退出会让 nft 收到 SIGPIPE,
# 在 set -o pipefail 下管道返回 141 导致误判; 统一改为先取输出再匹配
pf_masq_present() {
    local out
    out="$(nft list chain "$TABLE_FAMILY" "$TABLE_NAME" postrouting 2>/dev/null)"
    [[ $out == *masquerade* ]]
}

# 确保表 / 链 / masquerade 规则存在 (幂等)
ensure_pf_table() {
    pf_table_exists || nft add table "$TABLE_FAMILY" "$TABLE_NAME" \
        || { err "创建表 $TABLE_FAMILY $TABLE_NAME 失败"; return 1; }
    pf_chain_exists prerouting || nft add chain "$TABLE_FAMILY" "$TABLE_NAME" prerouting \
        '{ type nat hook prerouting priority dstnat; policy accept; }' \
        || { err "创建 prerouting 链失败"; return 1; }
    pf_chain_exists postrouting || nft add chain "$TABLE_FAMILY" "$TABLE_NAME" postrouting \
        '{ type nat hook postrouting priority srcnat; policy accept; }' \
        || { err "创建 postrouting 链失败"; return 1; }
    if ! pf_masq_present; then
        nft add rule "$TABLE_FAMILY" "$TABLE_NAME" postrouting \
            ct status dnat masquerade comment "\"pf:auto-snat\"" \
            || { err "添加 masquerade 规则失败"; return 1; }
    fi
    return 0
}

list_prerouting_raw() { nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" prerouting 2>/dev/null; }

count_forward_rules() {
    local n
    n="$(list_prerouting_raw | grep -cE "$RE_FWD_RULE" || true)"
    printf '%s' "${n:-0}"
}

# 解析当前转发规则到数组
RULE_PROTO=(); RULE_PORTS=(); RULE_IP=(); RULE_TPORTS=(); RULE_HANDLES=()
load_forward_rules() {
    RULE_PROTO=(); RULE_PORTS=(); RULE_IP=(); RULE_TPORTS=(); RULE_HANDLES=()
    local line
    while IFS= read -r line; do
        [[ $line =~ $RE_FWD_PARSE ]] || continue
        RULE_PROTO+=("${BASH_REMATCH[1]}")
        RULE_PORTS+=("${BASH_REMATCH[2]}")
        RULE_IP+=("${BASH_REMATCH[4]}")
        RULE_TPORTS+=("${BASH_REMATCH[6]}")
        RULE_HANDLES+=("${BASH_REMATCH[8]}")
    done < <(list_prerouting_raw)
    return 0
}

rule_target_text() {   # <索引> -> "192.168.1.100:8080" 或 "192.168.1.100 (端口保持)"
    local i="$1"
    if [[ -n ${RULE_TPORTS[$i]} ]]; then
        printf '%s:%s' "${RULE_IP[$i]}" "${RULE_TPORTS[$i]}"
    else
        printf '%s (端口保持)' "${RULE_IP[$i]}"
    fi
}

# ------------------------------- 输入校验 ------------------------------------
PORT_START=0; PORT_END=0

is_port_number() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

parse_portspec() {   # 解析 "8080" / "53000-54000" -> PORT_START / PORT_END
    local spec="$1" a b
    if [[ $spec =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    elif [[ $spec =~ ^[0-9]+$ ]]; then
        a="$spec"; b="$spec"
    else
        return 1
    fi
    is_port_number "$a" || return 1
    is_port_number "$b" || return 1
    (( 10#$a <= 10#$b )) || return 1
    PORT_START=$((10#$a)); PORT_END=$((10#$b))
    return 0
}

is_ipv4() {
    local ip="$1" octet
    local -a parts=()
    local IFS=.
    read -r -a parts <<< "$ip"
    [[ ${#parts[@]} -eq 4 ]] || return 1
    for octet in "${parts[@]}"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

# 列出内核中正在生效、但 MAIN_CONF 未声明的表 —— 启动/开机加载 nftables.service
# (其配置含 flush ruleset) 时这些表会被立即清除, 需要对应服务自行重新加载
unmanaged_live_tables() {
    nft_installed || return 0
    [[ -e $MAIN_CONF ]] || return 0
    local _ fam name
    nft list tables 2>/dev/null | while read -r _ fam name; do
        [[ -n ${fam:-} && -n ${name:-} ]] || continue
        name="${name%%\{*}"
        grep -qE "^[[:space:]]*table[[:space:]]+${fam}[[:space:]]+${name}([[:space:]{]|$)" "$MAIN_CONF" 2>/dev/null \
            || printf '%s %s\n' "$fam" "$name"
    done
}

# 打印表列表 (每行缩进)
print_table_list() {
    local t
    while IFS= read -r t; do
        [[ -n $t ]] && printf '        %s\n' "$t"
    done <<< "$1"
}

# ------------------------------- 持久化 --------------------------------------
ensure_persist_files() {
    mkdir -p "$CONF_DIR" || { err "无法创建目录 $CONF_DIR"; return 1; }
    if [[ ! -e $CONF_FILE ]]; then
        printf '#!/usr/sbin/nft -f\n# 由端口转发脚本管理, 暂无转发规则\n' > "$CONF_FILE" || return 1
        chmod 0644 "$CONF_FILE" 2>/dev/null || true
    fi
    if [[ ! -e $MAIN_CONF ]]; then
        printf '#!/usr/sbin/nft -f\n' > "$MAIN_CONF" || return 1
        chmod 0644 "$MAIN_CONF" 2>/dev/null || true
        info "已创建缺失的主配置 $MAIN_CONF"
    fi
    if ! grep -qF "include \"$CONF_FILE\"" "$MAIN_CONF" 2>/dev/null \
       && ! grep -qF "include \"$CONF_DIR/" "$MAIN_CONF" 2>/dev/null; then
        cp -a "$MAIN_CONF" "${MAIN_CONF}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        printf '\n# 由端口转发脚本添加: 引入端口转发规则\ninclude "%s"\n' "$CONF_FILE" >> "$MAIN_CONF" \
            || { err "写入 $MAIN_CONF 失败"; return 1; }
        ok "已向 $MAIN_CONF 添加 include 行 (原文件已备份)"
    fi
    return 0
}

# 把当前内核中的规则导出为可重复加载的配置文件
save_rules() {
    ensure_persist_files || return 1
    local tmp
    tmp="$(mktemp)" || { err "无法创建临时文件"; return 1; }
    {
        printf '#!/usr/sbin/nft -f\n'
        printf '# 本文件由 nftables 端口转发脚本自动生成, 请勿手动编辑\n'
        printf '# 生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# 说明: add + flush 保证重复加载不会产生重复规则\n'
        printf 'add table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf 'flush table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
        nft list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null
    } > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$CONF_FILE" || { err "写入 $CONF_FILE 失败"; rm -f "$tmp"; return 1; }
    return 0
}

# ------------------------------- 安装 / 启动 ---------------------------------
auto_install_nftables() {
    if ! command_exists apt-get; then
        err "未找到 apt-get, 自动安装功能仅支持 Debian / Ubuntu 系"
        return 1
    fi
    info "正在更新软件包索引 (apt-get update) ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update 失败, 仍尝试直接安装"
    info "正在安装 nftables ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables \
        || { err "apt-get install nftables 失败"; return 1; }
    if nft_installed; then
        ok "nftables 安装完成: $(nft --version 2>/dev/null)"
        return 0
    fi
    err "安装后仍未找到 nft 命令"; return 1
}

# 启动服务前保证主配置存在, 否则 nftables.service 会启动失败
ensure_main_conf_exists() {
    [[ -e $MAIN_CONF ]] && return 0
    printf '#!/usr/sbin/nft -f\n' > "$MAIN_CONF" || return 1
    chmod 0644 "$MAIN_CONF" 2>/dev/null || true
    info "已创建缺失的主配置 $MAIN_CONF"
    return 0
}

startup_checks() {
    printf '%s%s%s\n' "$C_BLD" "nftables 端口转发管理脚本 (Debian / Ubuntu)" "$C_RST"
    hr

    command_exists apt-get || warn "未检测到 apt-get: 非 Debian 系系统, 自动安装功能不可用"

    # 1) nftables 是否安装
    if nft_installed; then
        ok "检测到 nftables 已安装 ($(nft --version 2>/dev/null))"
    else
        warn "检测到系统未安装 nftables (缺少 nft 命令)"
        if confirm "是否使用本脚本自动安装 nftables?"; then
            auto_install_nftables \
                || { err "自动安装失败, 请手动执行: apt-get update && apt-get install -y nftables"; exit 1; }
        else
            err "nftables 未安装, 脚本无法继续"; exit 1
        fi
    fi

    # 2) 服务是否运行
    if ! has_systemd; then
        warn "未检测到 systemd, 跳过服务状态检查 (规则仅在本次运行期生效)"
        hr
        return 0
    fi
    if ! svc_unit_exists; then
        warn "未找到 systemd 单元 ${SERVICE}.service, 跳过服务状态检查"
        hr
        return 0
    fi
    if [[ $(svc_active_state) == active ]]; then
        ok "检测到 ${SERVICE} 服务正在运行"
    else
        warn "检测到 ${SERVICE} 服务未运行 (当前状态: $(svc_active_state))"
        ensure_main_conf_exists
        local lost
        lost="$(unmanaged_live_tables)"
        if [[ -n $lost ]]; then
            warn "启动会加载 $MAIN_CONF (内含 flush ruleset), 以下运行中的表将立即被清除:"
            print_table_list "$lost"
            warn "  这些表由 Docker / hysteria / fail2ban 等服务自行加载, 需重启对应服务才会恢复"
        fi
        if confirm "是否使用本脚本立即启动 ${SERVICE} 服务? (会重置当前规则集)"; then
            if systemctl start "$SERVICE"; then
                ok "${SERVICE} 服务已启动"
            else
                err "启动失败, 请手动检查: systemctl status $SERVICE"
            fi
        else
            warn "已跳过启动; 服务未运行/未设开机自启时, 规则重启后不会自动恢复 (可用菜单 5 开启自启)"
        fi
    fi
    hr
    return 0
}

# ------------------------------- 菜单功能 ------------------------------------
menu_add_forward() {
    title "添加端口转发"
    local pchoice ext_spec target_ip tspec_raw tspec="" i
    local -a protos=()

    printf '请选择转发协议:\n  1) TCP\n  2) UDP\n  3) TCP + UDP\n'
    read_line pchoice "请输入 [1-3] (默认 1): " || return 0
    [[ -z $pchoice ]] && pchoice=1
    case $pchoice in
        1) protos=(tcp) ;;
        2) protos=(udp) ;;
        3) protos=(tcp udp) ;;
        *) warn "无效的协议选择"; press_enter; return 0 ;;
    esac

    while :; do
        read_line ext_spec "请输入外部端口 (单个如 8080, 范围如 53000-54000): " || return 0
        ext_spec="${ext_spec// /}"
        parse_portspec "$ext_spec" && break
        warn "端口格式无效, 应为 1-65535 的端口或范围 (如 53000-54000)"
    done
    local ext_size=$(( PORT_END - PORT_START + 1 ))

    while :; do
        read_line target_ip "请输入转发目标 IP (IPv4): " || return 0
        target_ip="${target_ip// /}"
        is_ipv4 "$target_ip" && break
        warn "IP 地址格式无效, 请输入合法的 IPv4 地址"
    done

    read_line tspec_raw "请输入目标端口 (留空 = 与外部端口保持一致): " || true
    tspec_raw="${tspec_raw// /}"
    if [[ -n $tspec_raw ]]; then
        if ! parse_portspec "$tspec_raw"; then
            warn "目标端口格式无效"
            press_enter; return 0
        fi
        local t_size=$(( PORT_END - PORT_START + 1 ))
        if (( t_size != ext_size )); then
            warn "目标端口数量 ($t_size) 必须与外部端口数量 ($ext_size) 相同"
            warn "例: 外部 53000-54000 共 1001 个端口, 目标应填 63000-64000"
            press_enter; return 0
        fi
        if (( ext_size == 1 )); then tspec="$PORT_START"; else tspec="${PORT_START}-${PORT_END}"; fi
    fi

    hr
    printf '即将添加以下转发规则:\n'
    for i in "${protos[@]}"; do
        if [[ -n $tspec ]]; then
            printf '  %-3s  %s  ->  %s:%s\n' "${i^^}" "$ext_spec" "$target_ip" "$tspec"
        else
            printf '  %-3s  %s  ->  %s (端口保持不变)\n' "${i^^}" "$ext_spec" "$target_ip"
        fi
    done
    hr
    confirm "确认添加?" || { info "已取消"; press_enter; return 0; }

    ensure_pf_table || { press_enter; return 0; }
    local rc=0 rt
    for i in "${protos[@]}"; do
        if [[ -n $tspec ]]; then rt="$target_ip:$tspec"; else rt="$target_ip"; fi
        # comment 值里嵌入了字面双引号: nft 会把 argv 拼回一行再解析,
        # 若不带引号, 含空格的注释会被拆成多个 token 而报语法错误
        if nft add rule "$TABLE_FAMILY" "$TABLE_NAME" prerouting \
                "$i" dport "$ext_spec" dnat to "$rt" comment "\"pf:${i}:${ext_spec}:${rt}\""; then
            ok "已添加: ${i^^} $ext_spec -> $rt"
        else
            err "添加失败: ${i^^} $ext_spec -> $rt"
            rc=1
        fi
    done
    if (( rc == 0 )); then
        if save_rules; then ok "规则已持久化到 $CONF_FILE"; else warn "规则已生效, 但持久化失败"; fi
    fi
    press_enter
}

menu_show_forwards() {
    title "当前端口转发规则"
    load_forward_rules
    local n=${#RULE_HANDLES[@]} i
    if (( n == 0 )); then
        info "当前没有任何端口转发规则"
    else
        printf '%s %s %s %s\n' \
            "$(pad_disp "编号" 6)" "$(pad_disp "协议" 6)" "$(pad_disp "外部端口" 22)" "转发目标"
        for ((i = 0; i < n; i++)); do
            printf '%-6s %-6s %-22s %s\n' "$((i + 1))" "${RULE_PROTO[$i]^^}" "${RULE_PORTS[$i]}" "$(rule_target_text "$i")"
        done
        printf '\n共 %d 条转发规则\n' "$n"
    fi
    hr
    if pf_table_exists; then
        if pf_masq_present; then
            printf 'SNAT:       已启用 (ct status dnat masquerade, 保证回程流量经过本机)\n'
        else
            printf 'SNAT:       未启用 (不影响端口保持的转发, 跨网段/同网段回程可能不通)\n'
        fi
    fi
    if [[ -e $CONF_FILE ]]; then
        printf '持久化文件: %s\n' "$CONF_FILE"
    else
        printf '持久化文件: 尚未创建 (添加规则后自动生成)\n'
    fi
    if grep -qF "include \"$CONF_FILE\"" "$MAIN_CONF" 2>/dev/null \
       || grep -qF "include \"$CONF_DIR/" "$MAIN_CONF" 2>/dev/null; then
        printf '开机恢复:   已配置 (由 %s include)\n' "$MAIN_CONF"
    else
        printf '开机恢复:   未配置 (添加规则后自动写入)\n'
    fi
    if has_systemd && svc_unit_exists; then
        printf '开机自启:   %s (%s)\n' "$(enabled_text)" "$(svc_enabled_state)"
    fi
    press_enter
}

menu_delete_forward() {
    title "删除端口转发规则"
    load_forward_rules
    local n=${#RULE_HANDLES[@]} i tok a b j na nb ni okc=0
    if (( n == 0 )); then
        info "当前没有可删除的转发规则"
        press_enter; return 0
    fi
    for ((i = 0; i < n; i++)); do
        printf '%-4s %-5s %s -> %s\n' "$((i + 1)))" "${RULE_PROTO[$i]^^}" "${RULE_PORTS[$i]}" "$(rule_target_text "$i")"
    done
    printf '\n提示: 可输入单个编号 1 / 多个编号 1 3 / 范围 2-4 / all 全部删除, 直接回车取消\n'
    local sel
    read_line sel "请输入要删除的编号: " || return 0
    sel="${sel//,/ }"
    [[ -z ${sel// /} ]] && { info "已取消"; return 0; }

    local -a pick=() uniq=()
    for tok in $sel; do
        case $tok in
            all|ALL|All)
                for ((j = 0; j < n; j++)); do pick+=("$j"); done ;;
            *-*)
                a="${tok%%-*}"; b="${tok##*-}"
                if [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]]; then
                    na=$((10#$a)); nb=$((10#$b))
                    (( nb > n )) && nb=$n
                    for ((j = na; j <= nb; j++)); do
                        (( j >= 1 )) && pick+=("$((j - 1))")
                    done
                fi ;;
            *)
                if [[ $tok =~ ^[0-9]+$ ]]; then
                    ni=$((10#$tok))
                    (( ni >= 1 && ni <= n )) && pick+=("$((ni - 1))")
                fi ;;
        esac
    done
    if (( ${#pick[@]} == 0 )); then
        warn "没有有效的编号"
        press_enter; return 0
    fi
    mapfile -t uniq < <(printf '%s\n' "${pick[@]}" | sort -n -u)

    printf '\n将删除以下 %d 条规则:\n' "${#uniq[@]}"
    for i in "${uniq[@]}"; do
        printf '  - %s %s -> %s\n' "${RULE_PROTO[$i]^^}" "${RULE_PORTS[$i]}" "$(rule_target_text "$i")"
    done
    confirm "确认删除?" || { info "已取消"; press_enter; return 0; }

    for i in "${uniq[@]}"; do
        if nft delete rule "$TABLE_FAMILY" "$TABLE_NAME" prerouting handle "${RULE_HANDLES[$i]}"; then
            ok "已删除: ${RULE_PROTO[$i]^^} ${RULE_PORTS[$i]} -> $(rule_target_text "$i")"
            okc=$((okc + 1))
        else
            err "删除失败 (handle ${RULE_HANDLES[$i]})"
        fi
    done
    if (( okc > 0 )); then
        save_rules && ok "持久化配置已更新" || warn "持久化失败, 请手动检查 $CONF_FILE"
    fi
    press_enter
}

menu_clear_forwards() {
    title "清空所有端口转发规则"
    load_forward_rules
    local n=${#RULE_HANDLES[@]}
    if (( n == 0 )); then
        info "当前没有转发规则"
        press_enter; return 0
    fi
    warn "即将删除全部 $n 条转发规则 (SNAT/masquerade 规则保留)"
    confirm "确认清空?" || { info "已取消"; press_enter; return 0; }
    if nft flush chain "$TABLE_FAMILY" "$TABLE_NAME" prerouting; then
        ok "已清空 $n 条转发规则"
        save_rules && ok "持久化配置已更新" || warn "持久化失败, 请手动检查 $CONF_FILE"
    else
        err "清空失败"
    fi
    press_enter
}

menu_boot_autostart() {
    title "nftables 开机自启设置"
    if ! has_systemd; then
        warn "未检测到 systemd, 无法设置开机自启"
        press_enter; return 0
    fi
    if ! svc_unit_exists; then
        warn "未找到 systemd 单元 ${SERVICE}.service"
        press_enter; return 0
    fi
    local cur c
    cur="$(svc_enabled_state)"
    printf '当前状态: %s (%s)\n' "$(enabled_text)" "$cur"
    printf '运行状态: %s\n\n' "$(svc_active_state)"
    printf '  1) 开启开机自启 (systemctl enable %s)\n' "$SERVICE"
    printf '  2) 关闭开机自启 (systemctl disable %s)\n' "$SERVICE"
    printf '  0) 返回\n'
    printf '\n提示: 请勿执行 systemctl stop %s —— Debian 单元的 ExecStop 是 "nft flush ruleset",\n' "$SERVICE"
    printf '      会把包括本表在内的全部规则清空 (只需 disable 关自启即可).\n'
    read_line c "请输入 [0-2]: " || return 0
    case $c in
        1)
            if [[ $cur == enabled ]]; then
                info "开机自启已是开启状态"
                press_enter; return 0
            fi
            if [[ $cur == masked ]]; then
                warn "服务当前为 masked 状态, 请先执行: systemctl unmask $SERVICE"
                press_enter; return 0
            fi
            ensure_persist_files
            local lost
            lost="$(unmanaged_live_tables)"
            if [[ -n $lost ]]; then
                warn "开机加载 $MAIN_CONF (含 flush ruleset) 时, 以下表会先被清除:"
                print_table_list "$lost"
                warn "  由 Docker / hysteria / fail2ban 等自行加载的表在其服务启动后会自动重建;"
                warn "  若某服务并非开机自启, 请自行确认其规则不会丢失"
            fi
            confirm "确认开启 ${SERVICE} 开机自启?" || { press_enter; return 0; }
            if systemctl enable "$SERVICE"; then
                ok "已开启 ${SERVICE} 开机自启"
            else
                err "开启失败"
            fi
            ;;
        2)
            confirm "确认关闭 ${SERVICE} 开机自启?" || { press_enter; return 0; }
            if systemctl disable "$SERVICE"; then
                ok "已关闭 ${SERVICE} 开机自启"
            else
                err "关闭失败"
            fi
            ;;
        *) return 0 ;;
    esac
    press_enter
}

# ------------------------------- 主菜单 --------------------------------------
print_main_menu() {
    [[ -t 1 ]] && { clear 2>/dev/null || true; }
    local inst svc boot cnt
    if nft_installed; then inst="${C_GRN}已安装${C_RST}"; else inst="${C_RED}未安装${C_RST}"; fi
    if ! has_systemd; then
        svc="无systemd"; boot="无systemd"
    elif ! svc_unit_exists; then
        svc="单元缺失"; boot="单元缺失"
    else
        case "$(svc_active_state)" in
            active) svc="${C_GRN}运行中${C_RST}" ;;
            *)      svc="${C_YEL}$(svc_active_state)${C_RST}" ;;
        esac
        case "$(svc_enabled_state)" in
            enabled)  boot="${C_GRN}已启用${C_RST}" ;;
            disabled) boot="${C_YEL}已禁用${C_RST}" ;;
            *)        boot="$(svc_enabled_state)" ;;
        esac
    fi
    cnt="$(count_forward_rules)"

    printf '%s==================== nftables 端口转发管理 ====================%s\n' "$C_BLD" "$C_RST"
    printf 'nftables: %s   服务: %s   开机自启: %s   转发规则: %s 条\n' "$inst" "$svc" "$boot" "$cnt"
    hr
    printf '  1) 添加端口转发 (支持端口范围, TCP/UDP/TCP+UDP)\n'
    printf '  2) 查看当前转发规则\n'
    printf '  3) 删除转发规则\n'
    printf '  4) 清空所有转发规则\n'
    printf '  5) 开启 / 关闭 nftables 开机自启\n'
    printf '  0) 退出\n'
    hr
}

main() {
    require_root "$@"
    startup_checks
    local choice
    while :; do
        print_main_menu
        read_line choice "请输入选项: " || { printf '\n'; exit 0; }
        case $choice in
            1) menu_add_forward ;;
            2) menu_show_forwards ;;
            3) menu_delete_forward ;;
            4) menu_clear_forwards ;;
            5) menu_boot_autostart ;;
            0|q|Q|quit|exit) printf '再见!\n'; exit 0 ;;
            '') ;;
            *) warn "无效选项: $choice" ;;
        esac
    done
}

main "$@"
