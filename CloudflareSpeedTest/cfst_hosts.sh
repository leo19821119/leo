#!/bin/sh

#set -x # 开启调试，用于排查问题

#--- 变量定义 ---
# CloudflareST 目录路径
CLOUDFLAREST_DIR="/etc/CloudflareSpeedTest"
# 配置文件路径
DOMAINS_FILE="${CLOUDFLAREST_DIR}/domains.txt"
PROXY_SERVICES_FILE="${CLOUDFLAREST_DIR}/proxy_services.txt"
# hosts文件路径
HOSTS_FILE="/etc/hosts"
# 结果文件路径
RESULT_FILE="${CLOUDFLAREST_DIR}/result.csv"
TIMESTAMP_FILE="${CLOUDFLAREST_DIR}/last_test_timestamp"
# 测试文件路径
SPEED_URL="https://test.1852043.xyz/100m"
# 远程github上的domains.txt
REMOTE_URL="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/domains.txt"
TEMP_FILE="/tmp/domains_temp.txt"

# 默认参数 (可从命令行参数获取)
INTERVAL_HOURS=${1:-24} # 默认测试时间间隔（小时）
GET_THRESHOLD=${2:-300} # 默认测速IP选取最大延迟阈值（毫秒）
MAX_TEST_IPS=${3:-10}   # 默认单个域名最大测试IP数量
Name_CLOUDFLAREST_EXEC=${4:"cfst"}   # 默认CloudflareST 文件名

# CloudflareST 文件路径
CLOUDFLAREST_EXEC="${CLOUDFLAREST_DIR}/${Name_CLOUDFLAREST_EXEC}"

# CloudflareST 测速命令参数
CLOUDFLAREST_CMD_PARAMS="-tl ${GET_THRESHOLD} -tll 30 -tlr 0 -t 1 -n 500 -dn 10
 -url ${SPEED_URL} -f ${CLOUDFLAREST_DIR}/ip.txt -o ${CLOUDFLAREST_DIR}/result.csv"

#--- 函数定义 ---

# 检查必要文件是否存在
check_required_files() {
    for file in "$DOMAINS_FILE" "$PROXY_SERVICES_FILE" "$CLOUDFLAREST_EXEC" "$HOSTS_FILE"; do
        echo "检查文件文件: $file"
        if [ ! -f "$file" ]; then
            echo "错误：必要文件不存在: $file"
            exit 1
        fi
    done
    if [ ! -d "$CLOUDFLAREST_DIR" ]; then
        echo "错误：CloudflareST 目录不存在，请检查安装路径。"
        exit 1
    fi
}

# 服务操作通用函数：检查、停止、启动
service_action() {
    local service_name="$1"
    local action="$2" # "status", "stop", "start"
    local delay=0

    case "$action" in
        "status")
            /etc/init.d/"$service_name" status > /dev/null 2>&1
            return $?
            ;;
        "stop")
            echo "正在停止 $service_name 服务..."
            /etc/init.d/"$service_name" stop
            delay=2
            ;;
        "start")
            echo "正在启动 $service_name 服务..."
            /etc/init.d/"$service_name" start
            delay=3
            ;;
        *)
            echo "警告：未知的服务操作: $action" >&2
            return 1
            ;;
    esac
    sleep $delay
    echo "$service_name 服务已${action}。"
}

# 通用函数：清理行首尾空白和不可见字符
clean_line() {
    local line="$1"
    # 使用tr和sed清理行
    echo "$line" | tr -d '\000-\011\013-\037\177-\377' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# 停止所有正在运行的代理服务
stop_all_running_proxies() {
    echo "正在停止所有代理服务..."
    STOPPED_SERVICES=""
    # 直接读取文件，并在循环中清理和判断
    while IFS= read -r line || [ -n "$line" ]; do
        cleaned_line=$(clean_line "$line")
        # 跳过空行和以#或//开头的注释行
        if [ -z "$cleaned_line" ] || [ "${cleaned_line:0:1}" = "#" ] || [ "${cleaned_line:0:2}" = "//" ]; then
            continue
        fi
        if service_action "$cleaned_line" "status"; then
            service_action "$cleaned_line" "stop"
            STOPPED_SERVICES="$STOPPED_SERVICES $cleaned_line"
        else
            echo "$cleaned_line 服务未运行，无需停止。"
        fi
    done < "$PROXY_SERVICES_FILE"
    echo "所有代理服务已停止。"
}

# 启动所有之前停止的代理服务
start_all_stopped_proxies() {
    if [ -z "$STOPPED_SERVICES" ]; then
        echo "没有需要启动的代理服务。"
        return
    fi
    echo "正在启动之前停止的代理服务..."
    for service in $STOPPED_SERVICES; do
        service_action "$service" "start"
    done
    echo "所有代理服务已恢复。"
}

# 从hosts文件中删除指定域名的记录
remove_domains_from_hosts() {
    local domains_to_remove="$1"
    if [ -z "$domains_to_remove" ]; then
        echo "没有需要从hosts中删除的域名。"
        return
    fi
    echo "正在从hosts文件中删除指定域名..."
    for domain in $domains_to_remove; do
        # 删除包含该域名的行，使用安全的方式
        sed -i "/[[:space:]]$domain$/d" "$HOSTS_FILE"
        echo "已从hosts中删除域名: $domain"
    done
}

# 清理旧的hosts文件备份，只保留最新的10个
cleanup_backups() {
    echo "正在检查hosts文件备份数量，并清理旧备份..."
    local backup_path="${HOSTS_FILE}.bak.*"
    local all_backups=$(ls -t $backup_path 2>/dev/null)
    if [ -n "$all_backups" ]; then
        local backup_count=$(echo "$all_backups" | wc -l)
        if [ "$backup_count" -gt 10 ]; then
            echo "找到 $backup_count 个备份，将删除最旧的 $(($backup_count - 10)) 个备份..."
            echo "$all_backups" | tail -n +11 | xargs rm -f
            echo "旧备份已删除。"
        else
            echo "备份数量 ($backup_count) 未超过10个，无需清理。"
        fi
    else
        echo "没有找到hosts文件备份，无需清理。"
    fi
}

# 更新hosts文件中的指定域名，查找最佳IP
update_hosts_for_domain() {
    local domain="$1"
    local found_ip=""

    # 尝试从测速结果中寻找可用IP
    if [ -s "$RESULT_FILE" ]; then
        echo "开始为域名 ${domain} 验证可用IP (最多测试前 ${MAX_TEST_IPS} 个)..." >&2
        local ips=($(tail -n +2 "$RESULT_FILE" | head -n ${MAX_TEST_IPS} | awk -F, '{print $1}'))
        
        if [ ${#ips[@]} -eq 0 ]; then
            echo "警告：测速结果中没有可测试的IP。" >&2
        else
            for ip in "${ips[@]}"; do
                local url="https://${domain}"
                local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --resolve "${domain}:443:${ip}" "${url}")

                echo "  - 测试IP ${ip} 对域名 ${domain}，返回码: ${http_code}" >&2
                
                if [[ "$http_code" -ge 200 && "$http_code" -lt 500 ]]; then
                    echo "  - 找到可用IP: ${ip}" >&2
                    found_ip="$ip"
                    break # 找到后立即退出循环
                fi
            done
        fi
    else
        echo "错误：未找到测速结果文件或结果为空，无法尝试更换IP。" >&2
    fi

    # 根据是否找到可用IP来更新hosts
    if [ -n "$found_ip" ]; then
        echo "找到域名 ${domain} 的最佳IP: $found_ip"
        if grep -q "[[:space:]]$domain$" "$HOSTS_FILE"; then
            sed -i "s#^.*[[:space:]]$domain\$#$found_ip $domain#" "$HOSTS_FILE"
            echo "已更新hosts文件中 $domain 的IP为 $found_ip"
        else
            echo "$found_ip $domain" >> "$HOSTS_FILE"
            echo "已向hosts文件添加 $found_ip 指向 $domain"
        fi
        return 0 # 成功
    else
        echo "警告：未能为域名 ${domain} 找到可用的IP，将从hosts中删除此域名记录。" >&2
        sed -i "/[[:space:]]$domain$/d" "$HOSTS_FILE"
        return 1 # 失败
    fi
}

# 检查是否需要执行测试（只基于时间间隔）
should_run_test() {
    local current_time=$(date +%s)
    local last_test_time=0
    
    if [ -f "$TIMESTAMP_FILE" ]; then
        last_test_time=$(cat "$TIMESTAMP_FILE")
    else
        echo "没有找到上次测试时间记录，将执行完整测试。" >&2
        return 0
    fi
    
    local time_diff=$((current_time - last_test_time))
    local interval_seconds=$((INTERVAL_HOURS * 3600))
    
    echo "上次测试时间: $(date -d @$last_test_time)" >&2
    echo "当前时间: $(date -d @$current_time)" >&2
    echo "距离上次测试时间差: $time_diff 秒" >&2
    echo "测试间隔: $interval_seconds 秒" >&2
    
    if [ $time_diff -ge $interval_seconds ]; then
        echo "已达到测试时间间隔，需要执行测试。" >&2
        return 0 # true
    else
        echo "未达到测试时间间隔，跳过完整测试。" >&2
        return 1 # false
    fi
}

# 更新测试时间戳
update_test_timestamp() {
    date +%s > "$TIMESTAMP_FILE"
    echo "已更新测试时间戳: $(date)"
}

# 检查更新 远程github上的domains.txt
check_and_update_domains() {
    echo "检查 domains.txt 更新..."
    
    # 下载远程文件，如果失败则退出
    if ! curl -fsSL "$REMOTE_URL" -o "$TEMP_FILE"; then
        echo "无法访问远程URL，跳过更新"
        rm -f "$TEMP_FILE"
        return 1
    fi
    
    # 检查是否需要更新
    if [[ -f "$DOMAINS_FILE" ]] && cmp -s "$DOMAINS_FILE" "$TEMP_FILE"; then
        echo "本地文件已是最新版本"
        rm -f "$TEMP_FILE"
        return 0
    fi
    
    # 备份并更新文件
    [[ -f "$DOMAINS_FILE" ]] && cp "$DOMAINS_FILE" "${DOMAINS_FILE}.bak"
    mv "$TEMP_FILE" "$DOMAINS_FILE"
    echo "文件更新完成"
}

# 执行完整的测试和hosts更新流程
run_full_test() {
    echo "--- 开始执行完整的CloudflareSpeedTest测试流程 ---"

    # 备份当前的hosts文件并清理旧备份
    cp "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "已备份当前hosts文件."
    cleanup_backups

    # 检查更新 远程github上的domains.txt
    check_and_update_domains

    # 从 domains.txt 中分离需要更新和删除的域名
    local domains_to_update=""
    local domains_to_remove=""
    
    while IFS= read -r line || [ -n "$line" ]; do
        cleaned_line=$(clean_line "$line")
        
        # 跳过空行和以//开头的注释行
        if [ -z "$cleaned_line" ] || [ "${cleaned_line:0:2}" = "//" ]; then
            continue
        fi
        
        # 处理需要从hosts中删除的域名（#开头）
        if [ "${cleaned_line:0:1}" = "#" ]; then
            # 提取 # 后的域名并添加到删除列表
            domains_to_remove="$domains_to_remove $(echo "$cleaned_line" | sed 's/^#//')"
        else
            # 处理需要更新的域名（非#非//开头）
            domains_to_update="$domains_to_update $cleaned_line"
        fi
    done < "$DOMAINS_FILE"
    
    echo "找到需要更新的域名: $domains_to_update"
    echo "找到需要从hosts中删除的域名: $domains_to_remove"
    
    # 删除需要移除的域名
    remove_domains_from_hosts "$domains_to_remove"
    
    # 停止代理服务，运行测速
    stop_all_running_proxies
    echo "开始运行CloudflareSpeedTest测速..."
    "${CLOUDFLAREST_EXEC}" ${CLOUDFLAREST_CMD_PARAMS}

    # 检查测速结果
    if [ ! -s "$RESULT_FILE" ]; then
        echo "错误：未找到测速结果文件或结果为空，无法继续。"
        start_all_stopped_proxies
        exit 1
    fi
    
    # 为每个需要更新的域名寻找并更新hosts
    if [ -n "$domains_to_update" ]; then
        for domain in $domains_to_update; do
            update_hosts_for_domain "$domain"
        done
    else
        echo "没有需要更新的域名。"
    fi
    
    # 恢复服务
    /etc/init.d/dnsmasq restart
    echo "已重启dnsmasq服务。"
    start_all_stopped_proxies
    update_test_timestamp
    
    echo "脚本执行完毕。hosts文件已更新。"
}

# 检查所有启用域名的联通性，并在不通时尝试更换IP
check_all_connectivity() {
    echo "--- 检查域名连通性 ---"
    
    local domains_to_check=""
    # 重新解析 domains.txt，只获取需要更新的域名
    while IFS= read -r line || [ -n "$line" ]; do
        cleaned_line=$(clean_line "$line")
        if [ -z "$cleaned_line" ] || [ "${cleaned_line:0:2}" = "//" ] || [ "${cleaned_line:0:1}" = "#" ]; then
            continue
        fi
        domains_to_check="$domains_to_check $cleaned_line"
    done < "$DOMAINS_FILE"

    local any_failed=false

    if [ -z "$domains_to_check" ]; then
        echo "domains.txt中没有可用的域名。"
        return 0
    fi
    
    for domain in $domains_to_check; do
        local url="https://${domain}"
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url")
        
        echo "正在测试 $domain, HTTP状态码: $http_code" >&2
        
        if [[ "$http_code" -ge 200 && "$http_code" -lt 500 ]]; then
            echo "$domain 联通正常。"
        else
            echo "$domain 联通失败，尝试更换IP。"
            any_failed=true
            # 尝试更新hosts，若失败则删除记录
            update_hosts_for_domain "$domain"
        fi
    done

    if $any_failed; then
        /etc/init.d/dnsmasq restart
        echo "已重启dnsmasq服务。"
        echo "部分域名联通失败，已尝试更换IP。"
        return 1
    else
        echo "所有域名联通正常。"
        return 0
    fi
}

#--- 主程序入口 ---
check_required_files

echo "开始执行CloudflareSpeedTest自动化脚本..."
echo "测试间隔: $INTERVAL_HOURS 小时"
echo "IP延迟阈值: $GET_THRESHOLD 毫秒"
echo "单个域名最大测试IP数: $MAX_TEST_IPS"

if should_run_test; then
    run_full_test
else
    # 未到测试间隔，仅检查连通性并在必要时修复
    check_all_connectivity
fi

exit 0
