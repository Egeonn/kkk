#!/bin/bash

set -o pipefail

source_list="./ruleset_sources"
output_dir="./ruleset_txt"
group_name=""
temp_file=$(mktemp)
has_changes=false
group_raw_count=0

mkdir -p "$output_dir"

cleanup() {
    rm -f "$temp_file"
    rm -f *_remote.* 2>/dev/null || true
}
trap cleanup EXIT

save_group() {
    local name="$1"
    local input="$2"
    local raw_count="$3"
    
    [[ ! -s "$input" ]] && return 1
    
    local output="$output_dir/${name}.txt"
    local sorted=$(mktemp)
    
    sort -u "$input" > "$sorted" 2>/dev/null
    local final_count=$(wc -l < "$sorted")
    local dedup_count=$((raw_count - final_count))
    
    if [[ -f "$output" ]]; then
        if tail -n +5 "$output" | sort -u 2>/dev/null | cmp -s - "$sorted" 2>/dev/null; then
            echo "⏭️ $name: 原始 $raw_count 条，去重 $dedup_count 条，最终 $final_count 条，无变化"
            rm -f "$sorted"
            return 1
        else
            echo "📝 $name: 有更新"
            has_changes=true
        fi
    else
        echo "📝 $name: 首次生成"
        has_changes=true
    fi
    
    {
        echo "# Merged RuleSet for $name"
        echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Total Rules: $final_count"
        echo ""
        cat "$sorted"
    } > "$output"
    
    rm -f "$sorted"
    echo "✅ $name: 原始 $raw_count 条，去重 $dedup_count 条，最终 $final_count 条"
}

# ✅ 优化：空格清理 + 格式标准化
process_rules() {
    sed -E \
        -e 's/，/,/g' \
        -e 's/^[[:space:]]+//; s/[[:space:]]+$//' \      # ✅ 删除行首尾所有空格
        -e '/^#/d' \
        -e '/^$/d' \
        -e '/^DOMAIN-REGEX,/d' \
        -e '/7h1s_rul35et_i5_mad3_by_5ukk4w/d' \
        -e 's/^[•*-][[:space:]]*//' \
        -e 's/[[:space:]]*,[[:space:]]*/,/g' \           # ✅ 删除逗号前后所有空格
        -e 's/^\.(.+)$/DOMAIN-SUFFIX,\1/' \
        -e '/^[a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,}$/s/^/DOMAIN,/'
}

while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | xargs)
    [[ -z "$line" ]] && continue

    if [[ "$line" == \[*\] ]]; then
        [[ -n "$group_name" ]] && save_group "$group_name" "$temp_file" "$group_raw_count"
        group_name="${line#[}"
        group_name="${group_name%]}"
        > "$temp_file"
        group_raw_count=0
        echo ""
        echo "═══════════════════════════════════"
        echo "📁 开始分组：$group_name"
        echo "═══════════════════════════════════"
        continue
    fi

    url="$line"
    name=$(basename "${url%%\?*}" | sed 's/\.[^.]*$//')
    tmp=$(mktemp)
    
    echo "⬇️ 下载：$url"
    
    if ! curl -sL --fail --retry 2 --connect-timeout 15 --max-time 120 "$url" -o "$tmp"; then
        echo "  ❌ 下载失败"
        rm -f "$tmp"
        continue
    fi
    
    file_size=$(wc -c < "$tmp")
    if [[ "$file_size" -lt 50 ]]; then
        echo "  ❌ 文件过小 ($file_size 字节)"
        rm -f "$tmp"
        continue
    fi
    
    # ✅ 修复：流式处理，避免大文件读入变量导致 Broken Pipe
    if grep -qE '^payload:|^rules:' "$tmp" && command -v yq &> /dev/null; then
        # 尝试提取 YAML 中的 rules 或 payload
        if yq -r '.payload[]' "$tmp" 2>/dev/null | process_rules >> "$temp_file" 2>/dev/null; then
            :
        elif yq -r '.rules[]' "$tmp" 2>/dev/null | process_rules >> "$temp_file" 2>/dev/null; then
            :
        else
            cat "$tmp" | process_rules >> "$temp_file" 2>/dev/null || true
        fi
    else
        cat "$tmp" | process_rules >> "$temp_file" 2>/dev/null || true
    fi
    
    # 统计原始规则数（用于日志显示）
    rule_count=$(grep -c '.' "$tmp" 2>/dev/null || echo 0)
    echo "  📊 原始规则：$rule_count 条"
    group_raw_count=$((group_raw_count + rule_count))
    
    rm -f "$tmp"
done < "$source_list"

[[ -n "$group_name" ]] && save_group "$group_name" "$temp_file" "$group_raw_count"

echo ""
echo "═══════════════════════════════════"
echo "🎉 所有规则集生成完成！"
echo "═══════════════════════════════════"
if [[ "$has_changes" == "true" ]]; then
    echo "📢 检测到变化，需要提交"
else
    echo "📢 无变化，无需提交"
fi
