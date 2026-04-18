#!/bin/bash

set -o pipefail

source_list="./ruleset_sources"
output_dir="./ruleset_txt"
group_name=""
temp_file=$(mktemp)
has_changes=false

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
    sort -u "$input" > "$sorted"
    local final_count=$(wc -l < "$sorted")
    local dedup_count=$((raw_count - final_count))
    
    if [[ -f "$output" ]] && tail -n +5 "$output" | sort -u | cmp -s - "$sorted"; then
        echo "⏭️ $name: 原始 $raw_count 条，去重 $dedup_count 条，最终 $final_count 条，无变化"
        rm -f "$sorted"
        return 1
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
    has_changes=true
}

process_rules() {
    sed -E \
        -e 's/，/,/g' \
        -e '/^#/d' \
        -e '/^$/d' \
        -e '/^DOMAIN-REGEX,/d' \
        -e 's/^[•*-] *//' \
        -e 's/, +/,/g' \
        -e 's/^\+\.([a-zA-Z0-9.-]+)$/DOMAIN-SUFFIX,\1/' \
        -e 's/^\*\.([a-zA-Z0-9.-]+)$/DOMAIN-SUFFIX,\1/' \
        -e '/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}$/s/^/DOMAIN,/'
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
        group_urls=""
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
    
    if grep -qE '^payload:|^rules:' "$tmp" && command -v yq &> /dev/null; then
        rules=$(yq -r '.payload[]' "$tmp" 2>/dev/null || yq -r '.rules[]' "$tmp" 2>/dev/null || cat "$tmp")
    else
        rules=$(cat "$tmp")
    fi
    
    rule_count=$(printf '%s\n' "$rules" | grep -c '.' 2>/dev/null || echo 0)
    echo "  📊 原始规则：$rule_count 条"
    
    group_raw_count=$((group_raw_count + rule_count))
    group_urls="${group_urls}  - ${name} (${rule_count}条)\n"
    
    printf '%s\n' "$rules" | process_rules >> "$temp_file" 2>/dev/null || true
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
