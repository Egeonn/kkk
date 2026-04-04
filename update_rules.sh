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

# ================= 规则提取 =================
extract_rules() {
    local file="$1"
    local content=""

    # 检测是否为 YAML/Clash 格式
    if grep -qE '^\s*(payload|rules):' "$file" 2>/dev/null; then
        if command -v yq &> /dev/null; then
            content=$(yq -r '.payload[]? // .rules[]? // empty' "$file" 2>/dev/null || echo "")
        fi
    fi

    # 非 YAML 或提取失败时，直接读取原文
    if [[ -z "$content" ]]; then
        content=$(cat "$file")
    fi

    # 过滤注释与空行，输出纯净规则
    echo "$content" | grep -vE '^\s*(#|$)' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

# ================= 分组保存与 MRS 生成 =================
save_group() {
    local name="$1"
    local temp_file="$2" # 合并后的原始规则

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

    # ===== 写入完整 TXT =====
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
    # 🔪 拆分规则：域名 vs IP
    # ==============================
    local domain_file ip_file
    domain_file=$(register_temp)
    ip_file=$(register_temp)

    # 提取域名规则
    grep -E '^(DOMAIN|DOMAIN-SUFFIX),' "$full_sorted" > "$domain_file" 2>/dev/null || true
    # 提取 IP 规则 (IPv4/IPv6 CIDR)
    grep -E '^(IP-CIDR|IP-CIDR6),' "$full_sorted" > "$ip_file" 2>/dev/null || true

    local domain_count=$(wc -l < "$domain_file" | tr -d ' ')
    local ip_count=$(wc -l < "$ip_file" | tr -d ' ')

    # ===== 生成 Domain MRS =====
    if [[ "$domain_count" -gt 0 ]]; then
        local domain_mrs="$output_dir/${name}_domain.mrs"
        if [[ "$changed" == true || ! -f "$domain_mrs" ]]; then
            echo "🌐 生成 Domain MRS: $name ($domain_count 条)"
            if mihomo convert-ruleset text "$domain_file" "$domain_mrs"; then
                echo "📦 Domain MRS 已生成: $domain_mrs"
            else
                echo "❌ Domain MRS 生成失败"
            fi
        else
            echo "⏭️ Domain MRS 无变化，跳过"
        fi
    else
        echo "ℹ️ 无域名规则，跳过 Domain MRS"
    fi

    # ===== 生成 IP MRS =====
    if [[ "$ip_count" -gt 0 ]]; then
        local ip_mrs="$output_dir/${name}_ip.mrs"
        if [[ "$changed" == true || ! -f "$ip_mrs" ]]; then
            echo "🌐 生成 IP MRS: $name ($ip_count 条)"
            if mihomo convert-ruleset text "$ip_file" "$ip_mrs"; then
                echo "📦 IP MRS 已生成: $ip_mrs"
            else
                echo "❌ IP MRS 生成失败"
            fi
        else
            echo "⏭️ IP MRS 无变化，跳过"
        fi
    else
        echo "ℹ️ 无 IP-CIDR 规则，跳过 IP MRS"
    fi

    total_rules=$((total_rules + rule_count))
    return 0
}

# ================= 主执行逻辑 =================
echo "🚀 开始处理规则集..."

while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过空行、纯空格行和注释
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # 解析格式：分组名 | 源1,源2,源3
    IFS='|' read -r group_name source_str <<< "$line"
    group_name=$(echo "$group_name" | xargs)
    [[ -z "$group_name" ]] && continue

    echo "📥 开始合并分组: $group_name"
    merged_temp=$(register_temp)
    > "$merged_temp"

    # 按逗号拆分多个来源
    IFS=',' read -ra sources <<< "$source_str"
    for src in "${sources[@]}"; do
        src=$(echo "$src" | xargs) # 去除首尾空格
        [[ -z "$src" ]] && continue

        echo "   ⬇️ 获取: $src"
        src_file=$(register_temp)

        # 下载或复制
        if [[ "$src" =~ ^https?:// ]]; then
            if ! curl -fsSL --retry 2 --connect-timeout 5 "$src" -o "$src_file" 2>/dev/null; then
                echo "   ⚠️ 下载失败，跳过"
                continue
            fi
        else
            if [[ ! -f "$src" ]]; then
                echo "   ⚠️ 本地文件不存在，跳过: $src"
                continue
            fi
            cp "$src" "$src_file"
        fi

        # 提取并追加
        extract_rules "$src_file" >> "$merged_temp" 2>/dev/null || true
    done

    # 保存并生成 MRS
    if [[ -s "$merged_temp" ]]; then
        save_group "$group_name" "$merged_temp"
    else
        echo "⚠️ 分组 $group_name 未获取到任何有效规则"
    fi
done < "$source_list"

echo "========================================"
echo "🎉 处理完成！"
echo "📊 总规则数: $total_rules"
[[ "$has_changes" == true ]] && echo "🔄 检测到更新，已重新生成文件" || echo "✅ 所有规则集均为最新"
echo "========================================"
