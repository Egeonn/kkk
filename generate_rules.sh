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
    local final_count
    final_count=$(wc -l < "$sorted")
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

# ✅ 高性能规则处理
process_rules() {
    LC_ALL=C sed -E \
        -e 's/，/,/g' \
        -e 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        -e '/^#/d' \
        -e '/^$/d' \
        -e '/^DOMAIN-REGEX,/d' \
        -e '/7h1s_rul35et_i5_mad3_by_5ukk4w/d' \
        -e 's/^[•*-][[:space:]]*//' \
        -e 's/[[:space:]]*,[[:space:]]*/,/g' \
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
    tmp=$(mktemp)
    
    echo "⬇️ 下载：$url"
    
    if ! curl -sL --fail --retry 3 --retry-delay 2 \
        --connect-timeout 10 --max-time 60 \
        "$url" -o "$tmp"; then
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
    
    # ✅ YAML / 普通规则流式处理（无 cat → 无 Broken pipe）
    if grep -qE '^payload:|^rules:' "$tmp" && command -v yq &> /dev/null; then
        if yq -r '.payload[]' "$tmp" 2>/dev/null | process_rules >> "$temp_file"; then
            :
        elif yq -r '.rules[]' "$tmp" 2>/dev/null | process_rules >> "$temp_file"; then
            :
        else
            process_rules < "$tmp" >> "$temp_file" 2>/dev/null || true
        fi
    else
        process_rules < "$tmp" >> "$temp_file" 2>/dev/null || true
    fi
    
    # ✅ 更快统计
    rule_count=$(wc -l < "$tmp")
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
