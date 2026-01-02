#!/bin/sh

# 获取输入参数
INPUT_FORCE_FULL_TEST="${1:-0}"
INPUT_ENABLE_SPEED_TEST="${2:-1}"

#--- 脚本路径获取 ---
SCRIPT_PATH=$(readlink -f "$0")
CLOUDFLAREST_DIR=$(dirname "$SCRIPT_PATH")

#--- 架构自动识别 ---
ARCH=$(uname -m)
echo "CPU架构为 ${ARCH}"
case "$ARCH" in
    aarch64|armv7l|armv8l) DEFAULT_EXEC="cfst-arm64" ;;
    *) DEFAULT_EXEC="cfst" ;;
esac

#--- 配置 ---
NAME_EXEC=$DEFAULT_EXEC
NAME_IP_LIST="ip.txt"
NAME_SPEED_TEST_RESULT="result.csv"
NAME_TIMESTAMP="last_test_timestamp"
NAME_PROXY_SVC="proxy_services.txt"

FILE_EXEC="${CLOUDFLAREST_DIR}/${NAME_EXEC}"
FILE_IP_LIST="${CLOUDFLAREST_DIR}/${NAME_IP_LIST}"
FILE_SPEED_TEST_RESULT="${CLOUDFLAREST_DIR}/${NAME_SPEED_TEST_RESULT}"
FILE_TIMESTAMP="${CLOUDFLAREST_DIR}/${NAME_TIMESTAMP}"
FILE_PROXY_SVC="${CLOUDFLAREST_DIR}/${NAME_PROXY_SVC}"

MOSDNS_CONF="/etc/config/mosdns"
SPEED_URL="https://test.1852043.xyz/100m"
INTERVAL_HOURS=24
GET_THRESHOLD=300
MAX_TEST_IPS=3
MAX_BACKUPS=10

#--- 1. 工具函数：获取服务状态 (内部逻辑) ---
# 返回格式: "服务名:状态"
get_services_status() {
    local svc_list="$*"
    [ -z "$svc_list" ] && return

    for svc in $svc_list; do
        local init_script="/etc/init.d/$svc"
        local status="inactive"

        if [ -x "$init_script" ]; then
            local status_raw=$("$init_script" status 2>&1 | xargs)
            if [ -n "$status_raw" ]; then
                if echo "$status_raw" | grep -iqE "\binactive\b|\bstopped\b"; then
                    status="inactive"
                elif echo "$status_raw" | grep -iqE "\brunning\b|\bactive\b"; then
                    status="running"
                fi
            else
                pgrep -x "$init_script" >/dev/null && status="running"
            fi
        fi
        # 输出结果，供其他函数调用或打印
        echo "$svc:$status"
    done
}

#--- 2. 工具函数：读取配置并筛选出运行中的服务 ---
get_running_proxies_list() {
    [ ! -f "$FILE_PROXY_SVC" ] && return
    
    local all_configured_svcs=""
    local running_list=""

    # 第一步：从文件读取所有启用的服务名
    while read -r line || [ -n "$line" ]; do
        local svc=$(echo "$line" | sed 's/\r//g' | xargs)
        [ -z "$svc" ] || [ "${svc#\#}" != "$svc" ] && continue
        all_configured_svcs="$all_configured_svcs $svc"
    done < "$FILE_PROXY_SVC"

    [ -z "$all_configured_svcs" ] && return

    # 第二步：调用 get_services_status 获取状态列表并进行过滤
    # 我们处理 get_services_status 返回的 "name:status" 格式
    local status_results=$(get_services_status $all_configured_svcs)
    
    for entry in $status_results; do
        local name=${entry%:*}
        local state=${entry#*:}
        if [ "$state" = "running" ]; then
            running_list="$running_list $name"
        fi
    done

    echo "$running_list"
}

#--- 3. 核心函数：批量更新服务状态 ---
update_proxy_services_status() {
    local action="$1"
    shift
    local svc_list="$*"
    
    [ -z "$svc_list" ] && return

    for svc in $svc_list; do
        if [ -x "/etc/init.d/$svc" ]; then
            echo "正在发送 $action 指令: $svc"
            /etc/init.d/"$svc" "$action" >/dev/null 2>&1
        fi
    done
}

#--- 4. 辅助流程函数 ---
check_url_test_connectivity() {
    local retry_count=0
    local max_retries=3
    local wait_seconds=5

    while [ $retry_count -lt $max_retries ]; do
        retry_count=$((retry_count + 1))
        echo "正在检查网络连通性 (第 ${retry_count} 次尝试)..."
        
        local http_code=$(curl -I -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$SPEED_URL")
        echo "当前 HTTP 状态码: $http_code"

        # 判断状态码是否在正常范围内 (200-549)
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 550 ]; then
            echo "网络连接正常。"
            return 0
        fi

        if [ $retry_count -lt $max_retries ]; then
            echo "检测到连接异常，${wait_seconds}秒后进行下一次重试..."
            sleep $wait_seconds
        fi
    done

    echo "连续 ${max_retries} 次检查失败，判定为网络故障。"
    return 1
}

backup_mosdns_conf_file() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${MOSDNS_CONF}.${timestamp}.bak"
    if cp "$MOSDNS_CONF" "$backup_file"; then
        echo "已创建配置备份: $backup_file"
    else
        echo "警告: 配置备份失败！"
        return 1
    fi
    ls -t "${MOSDNS_CONF}".*.bak 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
}

update_mosdns_config() {
    [ ! -s "$FILE_SPEED_TEST_RESULT" ] && return 1
    local new_ips=$(tail -n +2 "$FILE_SPEED_TEST_RESULT" | awk -F, '$6 > 0 {print $1}' | head -n "$MAX_TEST_IPS")
    [ -z "$new_ips" ] && { echo "未发现有效 IP，跳过 MosDNS 更新。"; return 1; }

    echo "选定优选 IP 并写入配置:"
    echo "$new_ips"
    backup_mosdns_conf_file

    sed -i "/list local_dns/d" "$MOSDNS_CONF"
    for ip in $new_ips; do
        sed -i "/config mosdns/a \    list local_dns '$ip'" "$MOSDNS_CONF"
    done

    if [ -x "/etc/init.d/mosdns" ]; then
        echo "正在重启 MosDNS..."
        update_proxy_services_status "restart" "mosdns"
        # 等待 3 秒
        echo "等待重启响应 (3秒)..."
        sleep 3
        
        # 检查状态
        echo "--- 重启后状态核实 ---"
        get_services_status "mosdns"
        echo "--------------------"
        
    fi
}

#--- 5. 主执行逻辑 ---
run_cfspeed_and_update_cfdns() {
    echo "--- 开始执行完整测速与更新流程 ---"
    
    # 获取当前运行中的代理列表
    ACTIVE_PROXIES=$(get_running_proxies_list)
    
    if [ -n "$ACTIVE_PROXIES" ]; then
        echo "检测到活跃代理: $ACTIVE_PROXIES"
        
        # A. 停止服务
        echo "正在停止活跃代理..."
        update_proxy_services_status "stop" $ACTIVE_PROXIES
        
        # B. 停止后等待 3 秒
        echo "等待停止响应 (3秒)..."
        sleep 3
        
        # C. 批量检查状态
        echo "--- 停止后状态核实 ---"
        get_services_status $ACTIVE_PROXIES
        echo "--------------------"
    fi
    
    # --- 测速环节 ---
    if [ "$INPUT_ENABLE_SPEED_TEST" = "1" ]; then       
        "$FILE_EXEC" -tl ${GET_THRESHOLD} -tll 30 -tlr 0 -t 1 -n 500 -dn 10 \
            -url ${SPEED_URL} -f ${FILE_IP_LIST} -o ${FILE_SPEED_TEST_RESULT}
    else
        echo "跳过实际测速环节..."
    fi
    
    # --- 更新 MosDNS ---
    update_mosdns_config
    
    # --- 恢复服务 ---
    if [ -n "$ACTIVE_PROXIES" ]; then
        echo "正在恢复原有活跃代理..."
        update_proxy_services_status "start" $ACTIVE_PROXIES
        
        echo "等待启动响应 (3秒)..."
        sleep 3
        
        echo "--- 启动后状态核实 ---"
        get_services_status $ACTIVE_PROXIES
        echo "--------------------"
    fi
    
    date +%s > "$FILE_TIMESTAMP"
    echo "流程执行完毕: $(date)"
}

#--- 6. 运行判断逻辑 ---
[ ! -f "$FILE_EXEC" ] && { echo "找不到主程序"; exit 1; }
chmod +x "$FILE_EXEC"

if [ "$INPUT_FORCE_FULL_TEST" = "1" ]; then
    echo "强制执行模式..."
    run_cfspeed_and_update_cfdns
    exit 0
fi

FORCE_BY_FAILURE=0
check_url_test_connectivity || { echo "检测到故障，触发更新！"; FORCE_BY_FAILURE=1; }

FORCE_BY_TIME=0
CUR_TIME=$(date +%s)
if [ ! -f "$FILE_TIMESTAMP" ]; then
    FORCE_BY_TIME=1
else
    LAST_TIME=$(cat "$FILE_TIMESTAMP")
    NEXT_TIME=$((LAST_TIME + INTERVAL_HOURS * 3600))
    NEXT_TIME_STR=$(date -d "@$NEXT_TIME" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$NEXT_TIME" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    
    if [ "$CUR_TIME" -ge "$NEXT_TIME" ]; then
        FORCE_BY_TIME=1
    else
        echo "未到计划时间。预计下次执行: $NEXT_TIME_STR"
    fi
fi

if [ "$FORCE_BY_FAILURE" -eq 1 ] || [ "$FORCE_BY_TIME" -eq 1 ]; then
    run_cfspeed_and_update_cfdns
else
    echo "脚本退出（无需更新）。"
fi
