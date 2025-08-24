#!/bin/bash
# 北沐科技 FRP一键管理脚本 v9.99.99
# 功能：FRPS/FRPC安装、配置管理、端口管理、开机自启、彻底卸载

# 颜色输出函数
red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }
blue() { printf "\033[34m%s\033[0m\n" "$1"; }

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if command_exists ss; then
        ss -tuln | grep -q ":$port "
    elif command_exists netstat; then
        netstat -tuln | grep -q ":$port "
    else
        return 1
    fi
}

# 查找FRP安装路径
find_frp_install_path() {
    local frp_type=$1
    local default_path="/etc/$frp_type"
    
    # 1. 检查默认路径
    if [ -d "$default_path" ] && [ -x "$default_path/$frp_type" ]; then
        echo "$default_path"
        return
    fi
    
    # 2. 检查systemd服务文件中的路径
    if command_exists systemctl; then
        local service_path=$(systemctl cat "$frp_type" 2>/dev/null | grep -oP 'ExecStart=\K[^ ]+')
        if [ -n "$service_path" ] && [ -x "$service_path" ]; then
            echo "$(dirname "$service_path")"
            return
        fi
    fi
    
    # 3. 搜索常见安装位置
    local search_paths=(
        "/usr/local/$frp_type"
        "$HOME/$frp_type"
        "/opt/$frp_type"
        "/usr/bin/$frp_type"
        "/usr/local/bin/$frp_type"
    )
    
    for path in "${search_paths[@]}"; do
        if [ -x "$path" ]; then
            echo "$(dirname "$path")"
            return
        fi
    done
    
    # 未找到
    echo ""
}

# 主菜单
show_menu() {
    clear
    blue "=============================="
    blue " 北沐科技 FRP一键管理脚本 v7.8.3"
    blue "==============================="
    echo "1. ⚙️ 安装 FRP 服务端（frps）"
    echo "2. ⚙️ 安装 FRP 客户端（frpc）"
    echo "3. 🔄 管理穿透端口（增/删/改）"
    echo "4. 🚀 开机自启管理"
    echo "5. ❌ 彻底卸载 FRP"
    echo "6. 🔍 检测 FRP 安装状态(仅限默认安装的使用）"
    echo "7. ℹ️ 使用帮助"
    echo "8. 🚪 退出脚本"
    read -p "请输入选项 [1-8]: " choice

    case "$choice" in
        1) install_frp "frps" ;;
        2) install_frp "frpc" ;;
        3) manage_proxy ;;
        4) autostart_manager ;;
        5) uninstall_frp ;;
        6) check_frp_status ;;
        7) show_usage; read -p "按任意键返回主菜单..."; show_menu ;;
        8) green "感谢使用，脚本已退出"; exit 0 ;;
        *) red "无效选项，请重试"; sleep 1; show_menu ;;
    esac >&2
}

# 检查FRP安装状态
check_frp_status() {
    clear
    blue "===== FRP安装状态检测 ====="
    
    for frp_type in "frps" "frpc"; do
        echo -e "\n[ $frp_type 状态 ]"
        local install_path=$(find_frp_install_path "$frp_type")
        
        if [ -z "$install_path" ]; then
            red "未检测到 $frp_type 安装"
            continue
        fi
        
        green "安装路径: $install_path"
        
        # 检查可执行文件
        if [ -x "$install_path/$frp_type" ]; then
            green "可执行文件: 存在 (版本: $("$install_path/$frp_type" -v 2>&1 | head -n 1))"
        else
            red "可执行文件: 缺失或不可执行"
        fi
        
        # 检查配置文件
        if [ -f "$install_path/$frp_type.ini" ]; then
            green "配置文件: 存在 (大小: $(du -h "$install_path/$frp_type.ini" | awk '{print $1}'))"
            
            # 检查配置完整性
            if [ "$frp_type" = "frpc" ] && ! grep -q "token=" "$install_path/$frp_type.ini"; then
                yellow "⚠️ 配置警告: token未配置"
            fi
        else
            yellow "配置文件: 缺失"
        fi
        
        # 检查服务状态
        if command_exists systemctl; then
            local service_status=$(systemctl is-active "$frp_type" 2>/dev/null)
            case "$service_status" in
                active) green "服务状态: 运行中" ;;
                inactive) yellow "服务状态: 已安装但未运行" ;;
                failed) red "服务状态: 启动失败" ;;
                *) yellow "服务状态: 未配置systemd服务" ;;
            esac
        fi
        
        # 检查进程
        if pgrep -f "$install_path/$frp_type" >/dev/null; then
            green "进程状态: 正在运行 (PID: $(pgrep -f "$install_path/$frp_type" | head -n 1))"
        else
            yellow "进程状态: 未运行"
        fi
    done
    
    read -p "按任意键返回主菜单..."
    show_menu
}

# 使用帮助
show_usage() {
    blue "用法提示："
    echo "1. 安装时请确保网络通畅"
    echo "2. FRP安装包需为tar.gz格式"
    echo "3. 添加穿透前请确保FRPS服务已启动"
    echo "4. 卸载时请使用root权限运行以确保彻底删除"
    echo "5. 更新配置将保留安装目录，仅重新生成配置文件"
}

# 安装 FRPS/FRPC 通用逻辑（调整路径选择顺序）
install_frp() {
    local frp_type=$1
    local default_dir="/etc/$frp_type"
    local detected_path=$(find_frp_install_path "$frp_type")
    local pkg_url=""
    local pkg_name=""
    local install_dir=""

    # 改进的安装检测逻辑
    local is_installed=false
    if [ -n "$detected_path" ] && [ -x "$detected_path/$frp_type" ]; then
        is_installed=true
        yellow "检测到 $frp_type 已安装在: $detected_path"
        read -p "请选择操作: [1=重新安装 2=仅更新配置 3=取消] " action
        case "$action" in
            1)
                red "===== 重新安装流程 ====="
                red "请先通过菜单5卸载现有 $frp_type"
                read -p "是否现在跳转至卸载界面? [Y/n]: " go_to_uninstall
                if [[ "$go_to_uninstall" =~ ^[Yy]$ ]]; then
                    uninstall_frp
                else
                    red "已取消重新安装，请先卸载后再试"
                fi
                show_menu
                return
                ;;
            2)
                green "开始更新 $frp_type 配置..."
                generate_base_config "$frp_type" "$detected_path"
                # 重启服务
                if systemctl is-active --quiet "$frp_type"; then
                    systemctl restart "$frp_type"
                    green "$frp_type 服务已重启"
                else
                    green "$frp_type 配置已更新，请手动启动服务"
                fi
                show_menu
                return
                ;;
            3)
                green "操作已取消"
                show_menu
                return
                ;;
            *)
                red "无效选项，已取消操作"
                show_menu
                return
                ;;
        esac
    fi

    # 安装流程
    if [ "$is_installed" = false ]; then
        # ===== 调整：提前选择安装目录 =====
        read -p "请输入安装目录（默认: $default_dir）: " install_dir
        install_dir=${install_dir:-$default_dir}
        
        # 提前创建目录并验证
        if ! mkdir -p "$install_dir"; then
            red "无法创建安装目录 $install_dir（权限不足或路径无效）"
            show_menu
            return
        fi
        green "安装目录已确认: $install_dir"

        # 获取下载链接
        while true; do
            read -p "请输入 $frp_type 安装包（tar.gz）下载链接: " pkg_url
            if [[ -z $pkg_url || $pkg_url != *.tar.gz ]]; then
                red "链接无效（需为 tar.gz 格式），请重新输入"
            else
                pkg_name=$(basename "$pkg_url")
                break
            fi
        done

        # 下载
        green "正在下载 $frp_type 安装包（$pkg_name）..."
        if ! command_exists wget; then
            red "错误：未找到 wget，请先安装 wget"
            show_menu
            return
        fi
        if ! wget --show-progress -q "$pkg_url" -O "$pkg_name"; then
            red "下载失败！请检查网络或链接"
            read -p "是否重试？[Y/n]: " retry
            if [[ "$retry" =~ ^[Yy]$ ]]; then
                install_frp "$frp_type"
            else
                show_menu
            fi
            return
        fi
        green "下载完成！"

        # 解压+清理
        green "正在解压..."
        local temp_dir=$(mktemp -d)
        if ! tar -zxf "$pkg_name" -C "$temp_dir"; then
            red "解压失败！安装包可能损坏"
            rm -rf "$temp_dir" "$pkg_name"
            show_menu
            return
        fi
        rm -f "$pkg_name"

        # 查找解压目录
        local extract_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "frp_*" | head -n 1)
        if [ ! -d "$extract_dir" ]; then
            red "未找到有效的FRP目录！"
            rm -rf "$temp_dir"
            show_menu
            return
        fi

        cd "$extract_dir" || { red "进入解压目录失败"; rm -rf "$temp_dir"; show_menu; return; }
        # 只保留目标程序
        if [[ $frp_type == "frps" ]]; then
            rm -f frpc* README* LICENSE*
        else
            rm -f frps* README* LICENSE*
        fi

        # 复制文件到预选择的安装目录
        if ! cp -f * "$install_dir/"; then
            red "文件复制失败！"
            cd - >/dev/null && rm -rf "$temp_dir" && show_menu && return
        fi
        cd - >/dev/null && rm -rf "$temp_dir"

        # 验证安装
        if [ ! -x "$install_dir/$frp_type" ]; then
            red "安装失败：未找到可执行文件！"
            rm -rf "$install_dir"
            show_menu
            return
        fi

        green "$frp_type 已成功安装到: $install_dir"
        generate_base_config "$frp_type" "$install_dir"

        # 启动选项
        red "注意：当前终端启动后，关闭终端进程会终止进程"
        read -p "启动方式 (1=临时启动 2=服务管理 3=稍后): " start_choice
        case "$start_choice" in
            1)
                cd "$install_dir" && ./$frp_type -c ./$frp_type.ini && green "启动完成，按Ctrl+C停止"
                ;;
            2)
                autostart_manager
                ;;
            *)
                green "安装完成"
                sleep 1
                ;;
        esac
    fi

    show_menu
}

# 生成基础配置（修复else语法错误）
generate_base_config() {
    local frp_type="$1"
    local install_dir="$2"
    local config_path="$install_dir/$frp_type.ini"

    # 备份旧配置
    if [ -f "$config_path" ]; then
        local backup_path="$config_path.bak.$(date +%Y%m%d%H%M%S)"
        cp "$config_path" "$backup_path"
        green "已备份旧配置至: $backup_path"
    fi

    if [[ "$frp_type" == "frps" ]]; then
        # FRPS 配置
        while true; do
            read -p "请设置监听端口（默认:7000）: " bind_port
            bind_port=${bind_port:-7000}
            if [[ "$bind_port" =~ ^[0-9]+$ ]] && [ "$bind_port" -ge 1 ] && [ "$bind_port" -le 65535 ] && ! check_port "$bind_port"; then
                break
            else
                red "端口无效或已被占用，请重试"
            fi
        done

        read -p "面板端口（默认:7500）: " dash_port
        dash_port=${dash_port:-7500}

        read -p "面板账号（默认:admin）: " dash_user
        dash_user=${dash_user:-admin}
        
        while true; do
            read -p "面板密码（必填）: " dash_pwd
            [[ -n $dash_pwd ]] && break || red "密码不能为空"
        done
        
        read -p "HTTP 端口（默认:7080）: " http_port
        http_port=${http_port:-7080}
        read -p "HTTPS 端口（默认:7081）: " https_port
        https_port=${https_port:-7081}
        
        while true; do
            read -p "16位Token（必填）: " token
            if [[ -n $token && ${#token} -eq 16 && $token =~ ^[A-Za-z0-9]+$ ]]; then
                break
            else
                red "需16位字母/数字"
            fi
        done

        cat > "$config_path" << EOF
[common]
bind_port = $bind_port
dashboard_port = $dash_port
dashboard_user = $dash_user
dashboard_pwd = $dash_pwd
vhost_http_port = $http_port
vhost_https_port = $https_port
token = $token
EOF
    else
        # FRPC 配置 - 确保token总是被保存
        while true; do
            read -p "FRPS 服务器IP（必填）: " server_ip
            [[ -n $server_ip ]] && break || red "IP不能为空"
        done
        
        read -p "FRPS 端口（默认:7000）: " server_port
        server_port=${server_port:-7000}
        
        while true; do
            read -p "Token（必填）: " token
            [[ -n $token ]] && break || red "Token不能为空"
        done

        read -p "配置穿透？（任意键继续，回车跳过）: " proxy_choice
        
        # 无论是否配置穿透，都生成包含token的配置文件
        cat > "$config_path" << EOF
[common]
server_addr = $server_ip
server_port = $server_port
token = $token
EOF
        
        if [[ -n $proxy_choice ]]; then
            while true; do
                read -p "服务名称（必填）: " proxy_name
                [[ -n $proxy_name ]] && break || red "名称不能为空"
            done
            
            read -p "连接类型（默认: tcp）: " proxy_type
            proxy_type=${proxy_type:-tcp}
            
            read -p "本地端口（默认: 22）: " local_port
            local_port=${local_port:-22}
            
            read -p "远程端口（默认: 88）: " remote_port
            remote_port=${remote_port:-88}

            cat >> "$config_path" << EOF

[$proxy_name]
type = $proxy_type
local_ip = 127.0.0.1
local_port = $local_port
remote_port = $remote_port
EOF
        else
            green "已生成基础配置文件，未添加穿透规则"
            sleep 1
        fi
    fi
    green "配置文件已生成: $config_path"
}

# 管理穿透端口（修复common规则显示问题）
manage_proxy() {
    local default_dir="/etc/frpc"
    
    # 用户输入安装目录
    read -p "请输入frpc安装目录（默认: $default_dir）: " install_dir
    install_dir=${install_dir:-$default_dir}
    local config_path="$install_dir/frpc.ini"
    
    # 验证配置文件是否存在
    if [ ! -f "$config_path" ]; then
        red "错误：未找到配置文件 $config_path"
        read -p "按任意键返回主菜单..."
        show_menu
        return
    fi

    local -a proxies=()
    local name=""
    local type=""
    local lport=""
    local rport=""

    # 读取现有穿透规则（跳过common段）
    while IFS= read -r line; do
        # Remove comments and whitespace
        line=$(echo "$line" | sed 's/[ \t]*#.*//;s/^[ \t]*//;s/[ \t]*$//')
        [ -z "$line" ] && continue
        
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            # New section - skip common
            section="${BASH_REMATCH[1]}"
            if [ "$section" = "common" ]; then
                name=""  # Reset to skip common section
                continue
            fi
            # Save previous rule
            if [ -n "$name" ]; then
                proxies+=("$name:$type:$lport:$rport")
            fi
            name="$section"
            type=""
            lport=""
            rport=""
            continue
        fi
        
        # Extract configuration items
        if [[ "$line" =~ ^type[[:space:]]*=[[:space:]]*([^[:space:]]+) ]]; then
            type="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^local_port[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
            lport="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^remote_port[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
            rport="${BASH_REMATCH[1]}"
        fi
    done < "$config_path"

    # Save last rule
    if [ -n "$name" ]; then
        proxies+=("$name:$type:$lport:$rport")
    fi

    # Filter invalid rules named "common"
    local filtered_proxies=()
    for proxy in "${proxies[@]}"; do
        IFS=':' read -r n t lp rp <<< "$proxy"
        if [ "$n" != "common" ]; then
            filtered_proxies+=("$proxy")
        else
            yellow "已自动过滤无效规则: $n"
        fi
    done
    proxies=("${filtered_proxies[@]}")

    # Management loop
    while true; do
        clear
        blue "===== FRPC穿透管理 =====\n"
        echo "配置文件: $config_path"
        echo "规则数量: ${#proxies[@]}"

        if [ ${#proxies[@]} -gt 0 ]; then
            echo -e "\n穿透列表："
            for i in "${!proxies[@]}"; do
                IFS=':' read -r n t lp rp <<< "${proxies[$i]}"
                if [ -z "$t" ] || [ -z "$lp" ] || [ -z "$rp" ]; then
                    printf " %2d. %-12s 类型:%-5s 内网:%-5s 远程:%-5s ⚠️ 规则不完整\n" $((i+1)) "$n" "${t:-缺失}" "${lp:-缺失}" "${rp:-缺失}"
                else
                    printf " %2d. %-12s 类型:%-5s 内网:%-5s %-5s\n" $((i+1)) "$n" "$t" "$lp" "$rp"
                fi
            done
        else
            yellow "\n暂无穿透规则"
        fi

        echo -e "\n操作："
        echo "1. ➕ 添加规则"
        echo "2. ➖ 删除规则"
        echo "3. ✏️ 修改规则"
        echo "4. 💾 保存配置"
        echo "5. ↩️ 返回"

        read -p "\n请选择操作 [1-5]: " op
        case "$op" in
            1) # Add rule
                read -p "规则名称（如ssh）: " name
                [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_] ]] && { red "名称只能包含字母、数字和下划线"; continue; }
                [[ "$name" == "common" ]] && { red "错误：名称不能为'common'（系统保留）"; continue; }
                
                read -p "连接类型（默认: tcp）: " type
                type=${type:-tcp}
                [[ ! "$type" =~ ^(tcp|udp|http|https|stcp|xtcp)$ ]] && { red "类型必须是tcp/udp/http/https/stcp/xtcp"; continue; }
                
                read -p "本地端口: " lport
                [[ ! "$lport" =~ ^[0-9]+$ || "$lport" -lt 1 || "$lport" -gt 65535 ]] && { red "本地端口必须是1-65535的数字"; continue; }
                
                read -p "远程端口: " rport
                [[ ! "$rport" =~ ^[0-9]+$ || "$rport" -lt 1 || "$rport" -gt 65535 ]] && { red "远程端口必须是1-65535的数字"; continue; }
                
                proxies+=("$name:$type:$lport:$rport")
                green "\n已添加规则: $name ($type $lport->$rport)"
                ;;
            2) # Delete rule
                [ ${#proxies[@]} -eq 0 ] && { red "无规则可删"; read -p "按任意键继续..."; continue; }
                
                read -p "请输入要删除的规则序号: " idx
                idx=$((idx-1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#proxies[@]} ]; then
                    IFS=':' read -r n t lp rp <<< "${proxies[$idx]}"
                    unset "proxies[$idx]"
                    proxies=("${proxies[@]}")  # Rebuild array index
                    green "\n已删除规则: $n"
                else
                    red "无效的序号"
                fi
                ;;
            3) # Modify rule
                [ ${#proxies[@]} -eq 0 ] && { red "无规则可改"; read -p "按任意键继续..."; continue; }
                
                read -p "请输入要修改的规则序号: " idx
                idx=$((idx-1))
                if [ $idx -lt 0 ] || [ $idx -ge ${#proxies[@]} ]; then
                    red "无效的序号"; read -p "按任意键继续..."; continue;
                fi
                
                IFS=':' read -r n t lp rp <<< "${proxies[$idx]}"
                echo -e "\n当前规则: $n ($t $lp->$rp)"
                
                read -p "新名称($n): " nn; nn=${nn:-$n}
                [[ -z "$nn" || "$nn" =~ [^a-zA-Z0-9_] ]] && { red "名称只能包含字母、数字和下划线"; read -p "按任意键继续..."; continue; }
                [[ "$nn" == "common" ]] && { red "错误：名称不能为'common'（系统保留）"; read -p "按任意键继续..."; continue; }
                
                read -p "新类型($t): " tt; tt=${tt:-$t}
                [[ ! "$tt" =~ ^(tcp|udp|http|https|stcp|xtcp)$ ]] && { red "类型必须是tcp/udp/http/https/stcp/xtcp"; read -p "按任意键继续..."; continue; }
                
                read -p "新本地端口($lp): " ll; ll=${ll:-$lp}
                [[ ! "$ll" =~ ^[0-9]+$ || "$ll" -lt 1 || "$ll" -gt 65535 ]] && { red "本地端口必须是1-65535的数字"; read -p "按任意键继续..."; continue; }
                
                read -p "新远程端口($rp): " rr; rr=${rr:-$rp}
                [[ ! "$rr" =~ ^[0-9]+$ || "$rr" -lt 1 || "$rr" -gt 65535 ]] && { red "远程端口必须是1-65535的数字"; read -p "按任意键继续..."; continue; }
                
                proxies[$idx]="$nn:$tt:$ll:$rr"
                green "\n已更新规则: $nn ($tt $ll->$rr)"
                ;;
            4) # Save configuration
                read -p "确定保存？输入 '北沐' 确认: " confirm
                [ "$confirm" != "北沐" ] && { green "取消保存"; read -p "按任意键继续..."; continue; }
                
                local tmp=$(mktemp)
                # Preserve common section and other configurations
                sed -n '/^\[common\]/,/^\[/p' "$config_path" | sed '$d' > "$tmp"
                
                for p in "${proxies[@]}"; do
                    IFS=':' read -r n t lp rp <<< "$p"
                    # Skip incomplete rules
                    if [ -z "$t" ] || [ -z "$lp" ] || [ -z "$rp" ]; then
                        yellow "跳过不完整规则: $n"
                        continue
                    fi
                    cat >> "$tmp" << EOF

[$n]
type = $t
local_ip = 127.0.0.1
local_port = $lp
remote_port = $rp
EOF
                done

                mv "$tmp" "$config_path" && green "\n配置已保存！" || { red "\n保存失败！"; read -p "按任意键继续..."; continue; }
                
                # Restart FRPC service
                if command_exists systemctl; then
                    systemctl restart frpc 2>/dev/null && green "FRPC服务已重启" || yellow "FRPC服务未配置，需手动重启"
                fi
                ;;
            5) show_menu; return ;;
            *) red "无效选项"; read -p "按任意键继续..."; ;;
        esac
        read -p "\n按任意键继续..." dummy
    done
}

# 开机自启管理
autostart_manager() {
    while true; do
        echo -e "\n===== 开机自启管理 =====\n"
        echo "1. FRPS服务端"
        echo "2. FRPC客户端"
        echo "3. 返回"
        read -p "选择 [1-3]: " choice
        case "$choice" in
            1|2)
                local frp_type
                [ "$choice" -eq 1 ] && frp_type="frps" || frp_type="frpc"
                local install_path=$(find_frp_install_path "$frp_type")
                [ -z "$install_path" ] && { red "未检测到 $frp_type 安装"; show_menu; return; }
                manage_service "$frp_type" "$install_path"
                ;;
            3) show_menu; return ;;
            *) red "无效选项"; read -p "按任意键继续..."; ;;
        esac
    done }

manage_service() {
    local frp_type=$1
    local install_path=$2
    local service="/etc/systemd/system/$frp_type.service"

    while true; do
        clear
        blue "===== $frp_type 服务管理 =====\n"
        if systemctl is-active --quiet "$frp_type" 2>/dev/null; then
            yellow "状态：运行中"
        elif systemctl is-enabled --quiet "$frp_type" 2>/dev/null; then
            yellow "状态：已启用，未运行"
        else
            yellow "状态未配置"
        fi

        echo -e "\n操作："
        echo "1. 启动服务"
        echo "2. 停止服务"
        echo "3. 重启服务"echo "4. 查看状态"
        echo "5. 安装开机自启"
        echo "6. 卸载开机自启"
        echo "7返回"

        read -p "\n请选择操作 [1-7]: " op
        case "$op" in
            1) systemctl start "$frp_type" && green "启动成功" || red "启动失败"; ;;
            2) systemctl stop "$frp_type" && green "停止成功" || red "停止失败"; ;;
            3) systemctl restart "$frp_type" && green "重启成功" || red "重启失败"; ;;
            4) systemctl status "$frp_type" --no-pager; ;;
            5)
                # 创建systemd服务文件
                cat > "$service" << EOF
[Unit]
Description=FRP $frp_type Service
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=$install_path/$frp_type -c $install_path/$frp_type.ini

[Install]
WantedBy=multi-user.target
EOF
                chmod 644 "$service"
                systemctl daemon-reload
                systemctl enable "$frp_type" && green "自启已安装" || red "安装失败"; ;;
            6)
                systemctl disable "$frp_type" >/dev/null 2>&1
                rm -f "$service"
                systemctl daemon-reload
                green "自启已卸载"; ;;
            7) return ;;
            *) red "无效选项"; ;;
        esac
        read -p "\n按任意键继续..." dummy
    done
}

# 使用初版脚本的卸载函数
uninstall_frp() {
    read -p "FRP类型 (1.frps 2.frpc): " frp_choice
    case $frp_choice in
        1) frp_type="frps"; default_dir="/etc/frps" ;;
        2) frp_type="frpc"; default_dir="/etc/frpc" ;;
        *) red "无效选择"; show_menu; return ;;
    esac

    read -p "卸载目录 (默认: $default_dir): " del_dir
    del_dir=${del_dir:-$default_dir}
    [[ ! -d $del_dir ]] && { green "目录不存在，无需卸载"; show_menu; return; }

    red "警告: 删除后无法恢复，是否继续? [Y/n]"
    read -p "" confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && { green "已取消"; show_menu; return; }

    # 停止服务
    if command_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q "$frp_type.service"; then
        systemctl stop "$frp_type" >/dev/null 2>&1
        systemctl disable "$frp_type" >/dev/null 2>&1
        rm -f "/etc/systemd/system/$frp_type.service" >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
    fi

    # 删除目录
    rm -rf "$del_dir"
    green "已卸载: $del_dir"
    show_menu
}

# 启动主菜单
show_menu
