#!/bin/bash

set -o pipefail

source_list="${SOURCE_LIST:-./ruleset_sources}"
output_dir="${OUTPUT_DIR:-./ruleset_txt}"
group_name=""
temp_group_file=$(mktemp)
has_changes=false
start_time=$(date +%s)

if [[ ! -f "$source_list" ]]; then
    echo "❌ 错误：$source_list 不存在"
    exit 1
fi

mkdir -p "$output_dir"

cleanup() {
    rm -f "$temp_group_file"
    rm -f *_remote.* 2>/dev/null || true
}
trap cleanup EXIT

extract_rules() {
    local file="$1"
    if grep -qE '^payload:|^rules:' "$file" 2>/dev/null && command -v yq &> /dev/null; then
        yq -r '.payload[]' "$file" 2>/dev/null || yq -r '.rules[]' "$file" 2>/dev/null || cat "$file"
    else
        cat "$file"
    fi
}

save_group() {
    local name="$1"
    local temp_file="$2"
    
    if [[ -s "$temp_file" ]]; then
        local output_file="$output_dir/${name}.txt"
        local temp_sorted=$(mktemp)
        sort -u "$temp_file" > "$temp_sorted"
        local rule_count=$(wc -l < "$temp_sorted")
        
        if [[ -f "$output_file" ]]; then
            if tail -n +5 "$output_file" | sort -u | cmp -s - "$temp_sorted"; then
                echo "⏭️ 分组 $name 共生成 $rule_count 条规则，无变化，跳过"
                rm -f "$temp_sorted"
                return 1
            else
                echo "📝 分组 $name 有更新"
                has_changes=true
            fi
        else
            echo "📝 分组 $name 首次生成"
            has_changes=true
        fi
        
        {
            echo "# Merged RuleSet for $name"
            echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "# Total Rules: $rule_count"
            echo ""
            cat "$temp_sorted"
        } > "$output_file"
        
        rm -f "$temp_sorted"
        echo "✅ 分组 $name 共生成 $rule_count 条规则"
        return 0
    else
        echo "⚠️ 分组 $name 无规则，跳过"
        return 1
    fi
}

# ✅ 优化：添加 DOMAIN-REGEX 过滤
process_rules() {
    sed -E \
        -e 's/，/,/g' \
        -e 's/^[-•*] *//' \
        -e 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        -e '/^$/d' \
        -e '/^#/d' \
        -e '/7h1s_rul35et_i5_mad3_by_5ukk4w/d' \
        -e '/^DOMAIN-REGEX,/d' \
        -e 's/ *, */,/g' \
        -e 's/^\+\.([a-zA-Z0-9.-]+)$/DOMAIN-SUFFIX,\1/' \
        -e 's/^\*\.([a-zA-Z0-9.-]+)$/DOMAIN-SUFFIX,\1/' \
        -e '/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}$/s/^/DOMAIN,/'
}

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    line=$(echo "$line" | xargs)
    [[ -z "$line" ]] && continue

    if [[ "$line" == \[*\] ]]; then
        if [[ -n "$group_name" ]]; then
            save_group "$group_name" "$temp_group_file" || true
        fi
        group_name="${line#[}"
        group_name="${group_name%]}"
        group_name=$(echo "$group_name" | xargs)
        > "$temp_group_file"
        echo "📁 开始分组：$group_name"
        continue
    fi

    remote_url="$line"
    clean_url="${remote_url%%\?*}"
    base=$(basename "$clean_url")
    name="${base%.*}"
    temp_file="${name}_remote.txt"

    echo "⬇️ 下载：$name"

    if ! curl -sL --fail --retry 2 --connect-timeout 15 --max-time 120 "$remote_url" -o "$temp_file"; then
        echo "  ⚠️ 下载失败"
        continue
    fi

    file_size=$(wc -c < "$temp_file")
    if [[ "$file_size" -lt 50 ]]; then
        rm -f "$temp_file"
        continue
    fi

    rules=$(extract_rules "$temp_file")
    [[ -z "$rules" ]] && { rm -f "$temp_file"; continue; }

    rule_count=$(printf '%s\n' "$rules" | grep -c '.' 2>/dev/null || echo 0)
    echo "  📊 原始规则：$rule_count 条"

    printf '%s\n' "$rules" | process_rules >> "$temp_group_file" 2>/dev/null || true
    rm -f "$temp_file"
done < "$source_list"

if [[ -n "$group_name" ]]; then
    save_group "$group_name" "$temp_group_file" || true
fi

end_time=$(date +%s)
duration=$((end_time - start_time))

echo ""
echo "🎉 所有规则集生成完成！"
echo "⏱️  耗时：${duration}秒"
if [[ "$has_changes" == "true" ]]; then
    echo "📢 检测到变化，需要提交"
else
    echo "📢 无变化，无需提交"
fi
