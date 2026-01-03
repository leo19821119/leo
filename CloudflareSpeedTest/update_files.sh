
#!/bin/bash

# 获取脚本所在目录
CLOUDFLAREST_DIR="$(cd "$(dirname "$0")" && pwd)"

# 定义文件和对应的URL
declare -A FILE_URLS=(    
    ["cfst_to_mosdns.sh"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/cfst_to_mosdns.sh"
    ["domains.txt"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/domains.txt"
    ["ip.txt"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/ip.txt"
    ["last_test_timestamp"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/last_test_timestamp"
    ["proxy_services.txt"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/proxy_services.txt"
    ["cfst"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/cfst"
    ["cfst-arm64"]="https://raw.githubusercontent.com/leo19821119/leo/refs/heads/main/CloudflareSpeedTest/cfst-arm64"
)

# 更新文件函数
update_file() {
    local file_name="$1"
    local remote_url="$2"
    local local_file="${CLOUDFLAREST_DIR}/${file_name}"
    local temp_file=$(mktemp)
    
    echo "检查文件: $file_name"
    
    # 尝试下载远程文件
    if curl -fsSL "$remote_url" -o "$temp_file" 2>/dev/null; then
        # 检查本地文件是否存在
        if [[ -f "$local_file" ]]; then
            # 比较文件内容
            if cmp -s "$local_file" "$temp_file"; then
                echo "  ✓ $file_name 已是最新版本"
                rm -f "$temp_file"
                return 0
            else
                echo "  ↻ $file_name 有更新，正在覆盖..."
                # 备份原文件（可选）
                if [[ -f "$local_file" ]]; then
                    cp "$local_file" "${local_file}.bak" 2>/dev/null
                fi
                # 覆盖本地文件
                mv "$temp_file" "$local_file"
                # 如果是脚本文件，确保有执行权限
                if [[ "$file_name" == *.sh ]] || [[ "$file_name" == "cfst" ]]; then
                    chmod +x "$local_file"
                fi
                echo "  ✓ $file_name 更新完成"
                return 0
            fi
        else
            # 本地文件不存在，直接创建
            echo "  + $file_name 不存在，创建新文件..."
            mv "$temp_file" "$local_file"
            # 如果是脚本文件，确保有执行权限
            if [[ "$file_name" == *.sh ]] || [[ "$file_name" == "cfst" ]]; then
                chmod +x "$local_file"
            fi
            echo "  ✓ $file_name 创建完成"
            return 0
        fi
    else
        echo "  ✗ 无法访问远程URL: $remote_url"
        rm -f "$temp_file"
        return 1
    fi
}

# 主函数
main() {
    echo "开始检查文件更新..."
    echo "工作目录: $CLOUDFLAREST_DIR"
    echo "========================================"
    
    local updated_count=0
    local total_count=0
    
    # 遍历所有文件
    for file_name in "${!FILE_URLS[@]}"; do
        local remote_url="${FILE_URLS[$file_name]}"
        if update_file "$file_name" "$remote_url"; then
            updated_count=$((updated_count + 1))
        fi
        total_count=$((total_count + 1))
        echo ""
    done
    
    echo "========================================"
    echo "更新完成: $updated_count/$total_count 个文件已检查并更新"
    
    # 如果有文件被更新，显示提示
    if [[ $updated_count -gt 0 ]]; then
        echo "注意: 部分文件已更新，建议重新运行相关脚本"
    fi
}

# 执行主函数
main "$@"


