#!/bin/bash
set -euo pipefail

source_list="ruleset_sources"
output_dir="ruleset_txt"

if [[ ! -f "$source_list" ]]; then
    echo "❌ 错误：找不到 $source_list 文件"
    exit 1
fi

mkdir -p "$output_dir"

# 全局状态
total_rules=0
has_changes=false

# ================= 安全临时文件管理 =================
declare -a TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

register_temp() {
    local tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# ================= 规则提取（保留完整参数，仅做基础清洗） =================
extract_rules() {
    local file="$1"
    local content=""

    if grep -qE '^\s*(payload|rules):' "$file" 2>/dev/null; then
        if command -v yq &> /dev/null; then
            content=$(yq -r '
                (.payload // .rules) | 
                if type == "array" then .[] 
                elif type == "object" then to_entries[].value 
                else . 
                end
            ' "$file" 2>/dev/null || echo "")
        fi
    fi

    [[ -z "$content" ]] && content=$(cat "$file")

    # 基础清洗：去注释、去YAML符号、规整首个逗号前后的空格
    # 🔥 关键：不使用 cut 截断，完整保留 ,no-resolve 等附加参数
    echo "$content" | \
        sed 's/#.*//' | \
        sed 's/^[[:space:]]*-[[:space:]]*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -vE '^$|^(payload|rules):' | \
        sed -E 's/^([A-Z-]+)[[:space:]]*,[[:space:]]*/\1,/' | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -E '^(DOMAIN-SUFFIX|DOMAIN|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|IP-ASN),' || true
}

# ================= 分组保存与 MRS 生成 =================
save_group() {
    local name="$1"
    local temp_file="$2"

    if [[ ! -s "$temp_file" ]]; then
        echo "⚠️ 警告：分组 $name 没有规则"
        return 1
    fi

    local output_file="$output_dir/${name}.txt"
    local full_sorted
    full_sorted=$(register_temp)
    sort -u "$temp_file" > "$full_sorted"

    local rule_count
    rule_count=$(wc -l < "$full_sorted" | tr -d ' ')

    # ===== 检查全集 TXT 是否变化 =====
    local changed=false
    if [[ -f "$output_file" ]]; then
        local existing_sorted
        existing_sorted=$(register_temp)
        tail -n +5 "$output_file" | sort -u > "$existing_sorted"
        if cmp -s "$existing_sorted" "$full_sorted"; then
            echo "⏭️ 分组 $name 无变化"
        else
            echo "📝 分组 $name 有更新"
            has_changes=true
            changed=true
        fi
    else
        echo "📝 分组 $name 首次生成"
        has_changes=true
        changed=true
    fi

    # ===== 写入完整 TXT（🔥 保持完整 Clash 格式，含 ,no-resolve） =====
    if [[ "$changed" == true ]]; then
        {
            echo "# Merged RuleSet for $name"
            echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "# Total Rules: $rule_count"
            echo ""
            cat "$full_sorted"
        } > "$output_file"
        echo "✅ TXT 已更新：$output_file ($rule_count 条)"
    fi

    # ==============================
    # 🔪 拆分规则：域名 vs IP（为 MRS 转换做格式适配）
    # ==============================
    local domain_file ip_file
    domain_file=$(register_temp)
    ip_file=$(register_temp)

    # ✅ 域名规则：保持原始格式 (DOMAIN,xxx) 直接用于 mihomo behavior=domain
    grep -E '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),' "$full_sorted" > "$domain_file" 2>/dev/null || true

    # ✅ IP 规则：🔥 去除前缀 + 截断附加参数（mihomo 转换器仅接受纯 CIDR）
    grep -E '^(IP-CIDR|IP-CIDR6),' "$full_sorted" 2>/dev/null | \
        sed -E 's/^(IP-CIDR|IP-CIDR6),//' | \
        cut -d',' -f1 | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' > "$ip_file" || true

    local domain_count ip_count
    domain_count=$(wc -l < "$domain_file" | tr -d ' ')
    ip_count=$(wc -l < "$ip_file" | tr -d ' ')

    # ===== 生成 Domain MRS (behavior=domain) =====
    if [[ "$domain_count" -gt 0 ]]; then
        local domain_mrs="$output_dir/${name}_domain.mrs"
        if [[ "$changed" == true || ! -f "$domain_mrs" ]]; then
            echo "🌐 生成 Domain MRS: $name ($domain_count 条)"
            if mihomo convert-ruleset domain text "$domain_file" "$domain_mrs" 2>&1; then
                echo "📦 Domain MRS 已生成: $domain_mrs"
            else
                echo "❌ Domain MRS 生成失败"
                head -3 "$domain_file" >&2
            fi
        else
            echo "⏭️ Domain MRS 无变化，跳过"
        fi
    else
        echo "ℹ️ 无域名规则，跳过 Domain MRS"
    fi

    # ===== 生成 IP MRS (behavior=ipcidr) =====
    if [[ "$ip_count" -gt 0 ]]; then
        local ip_mrs="$output_dir/${name}_ip.mrs"
        if [[ "$changed" == true || ! -f "$ip_mrs" ]]; then
            echo "🌐 生成 IP MRS: $name ($ip_count 条)"
            # 🔥 输入文件必须为 纯CIDR 格式，mihomo 不接受 ,no-resolve
            if mihomo convert-ruleset ipcidr text "$ip_file" "$ip_mrs" 2>&1; then
                echo "📦 IP MRS 已生成: $ip_mrs"
            else
                echo "❌ IP MRS 生成失败"
                head -3 "$ip_file" >&2
            fi
        else
            echo "⏭️ IP MRS 无变化，跳过"
        fi
    else
        echo "ℹ️ 无 IP 规则，跳过 IP MRS"
    fi

    total_rules=$((total_rules + rule_count))
    return 0
}

# ================= 主执行逻辑 =================
echo "🚀 开始处理规则集 (格式: [Group] + 远程URL)..."

current_group=""
declare -a current_sources=()

process_pending_group() {
    local name="$1"
    shift
    local sources=("$@")
    
    [[ -z "$name" || ${#sources[@]} -eq 0 ]] && return 0
    
    echo "📥 开始合并分组: $name (${#sources[@]} 个来源)"
    local merged_temp
    merged_temp=$(register_temp)
    > "$merged_temp"

    for src in "${sources[@]}"; do
        src=$(echo "$src" | xargs)
        [[ -z "$src" || "$src" =~ ^# ]] && continue

        if [[ ! "$src" =~ ^https?:// ]]; then
            echo "   ⚠️ 仅支持远程链接，跳过: $src"
            continue
        fi

        echo "   ⬇️ 获取: $src"
        local src_file
        src_file=$(register_temp)

        if ! curl -fsSL --retry 2 --connect-timeout 5 "$src" -o "$src_file" 2>/dev/null; then
            echo "   ⚠️ 下载失败，跳过: $src"
            continue
        fi

        extract_rules "$src_file" >> "$merged_temp" 2>/dev/null || true
    done

    if [[ -s "$merged_temp" ]]; then
        save_group "$name" "$merged_temp"
    else
        echo "⚠️ 分组 $name 未获取到任何有效规则"
    fi
}

# 逐行解析配置文件
while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
        group_name="${BASH_REMATCH[1]:-}"
        if [[ -z "$group_name" ]]; then
            echo "⚠️ 警告: 无效分组头 '$line'，已忽略"
            continue
        fi
        
        if [[ -n "$current_group" && ${#current_sources[@]} -gt 0 ]]; then
            process_pending_group "$current_group" "${current_sources[@]}"
        fi
        current_group="$group_name"
        current_sources=()
        echo "🔍 解析到新分组: [$current_group]"
        continue
    fi

    if [[ -n "$current_group" ]]; then
        current_sources+=("$line")
    else
        echo "⚠️ 警告: 链接 '$line' 未在任何分组下，已忽略"
    fi
done < "$source_list"

# 处理最后一个分组
if [[ -n "$current_group" && ${#current_sources[@]} -gt 0 ]]; then
    process_pending_group "$current_group" "${current_sources[@]}"
fi

echo "========================================"
echo "🎉 处理完成！"
echo "📊 总规则数: $total_rules"
[[ "$has_changes" == true ]] && echo "🔄 检测到更新，已重新生成文件" || echo "✅ 所有规则集均为最新"
echo "========================================"
