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
    local input="$2"        # 这是经过 sed 清洗后的临时文件
    local raw_count="$3"    # 原始文件的总行数
    
    [[ ! -s "$input" ]] && return 1
    
    local output="$output_dir/${name}.txt"
    local sorted=$(mktemp)
    
    # 1. 统计清洗后的有效行数 (未去重)
    local valid_count
    valid_count=$(wc -l < "$input")
    
    # 2. 计算被 sed 清洗掉的行数 (注释、空行、正则等)
    local filtered_count=$((raw_count - valid_count))
    
    # 3. 进行排序和真正的去重
    sort -u "$input" > "$sorted" 2>/dev/null
    
    # 4. 统计最终的规则数
    local final_count
    final_count=$(wc -l < "$sorted")
    
    # 5. 计算真正的重复条数
    local dedup_count=$((valid_count - final_count))
    
    if [[ -f "$output" ]]; then
        if tail -n +5 "$output" | sort -u 2>/dev/null | cmp -s - "$sorted" 2>/dev/null; then
            echo "⏭️  $name: 无变化 (原始 $raw_count 行，清洗 $filtered_count 行，去重 $dedup_count 条，最终 $final_count 条)"
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
    echo "✅ $name: 原始 $raw_count 行，清洗 $filtered_count 行，去重 $dedup_count 条，最终 $final_count 条"
}
process_rules() {
    LC_ALL=C sed -E \
        -e '1s/^\xef\xbb\xbf//' \
        -e 's/，/,/g' \
        -e 's/[[:space:]]+#.*$//' \
        -e 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        -e '/^[[:space:]]*#/d' \
        -e '/^[#=\-\*]+$/d' \
        -e '/^[[:space:]]*EOF[[:space:]]*$/d' \
        -e '/^$/d' \
        -e '/^(payload|rules):/d' \
        -e 's/^[•*-][[:space:]]+//' \
        -e "s/^['\"]//; s/['\"]$//" \
        -e '/^DOMAIN-REGEX,/d' \
        -e 's/[[:space:]]*,[[:space:]]*/,/g' \
        -e 's/^\+\.(.+)$/DOMAIN-SUFFIX,\1/' \
        -e 's/^\.(.+)$/DOMAIN-SUFFIX,\1/' \
        -e '/^[a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,}$/s/^/DOMAIN,/' \
        -e '/^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/s/^/IP-CIDR,/' \
        -e '/^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(\/[0-9]{1,3})?$/s/^/IP-CIDR6,/' \
        -e '/skk\.moe$/d'
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
    
    echo "⬇️  下载：$url"
    
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
    
    # ✅ 统一按文本流式处理，兼容 Surge 文本与 Clash YAML 格式
    process_rules < "$tmp" >> "$temp_file" 2>/dev/null || true
    
    # 统计条数
    rule_count=$(wc -l < "$tmp")
    echo "  📊 原始行数：$rule_count 行"
    group_raw_count=$((group_raw_count + rule_count))
    
    rm -f "$tmp"
done < "$source_list"

[[ -n "$group_name" ]] && save_group "$group_name" "$temp_file" "$group_raw_count"

echo ""
echo "═══════════════════════════════════"
echo "所有规则集生成完成"
echo "═══════════════════════════════════"

if [[ "$has_changes" == "true" ]]; then
    echo "检测到变化，需要提交"
else
    echo "无变化，无需提交"
fi
