#!/bin/bash

set -euo pipefail

source_list="ruleset_sources"
output_dir="ruleset_txt"

if [[ ! -f "$source_list" ]]; then
    echo "❌ 错误：找不到 $source_list 文件"
    exit 1
fi

mkdir -p "$output_dir"

group_name=""
temp_group_file=$(mktemp)
total_rules=0
has_changes=false

cleanup() {
    rm -f "$temp_group_file"
    rm -f *_remote.* 2>/dev/null || true
}
trap cleanup EXIT

extract_rules() {
    local file="$1"
    local content=""

    if grep -qE '^payload:|^rules:' "$file" 2>/dev/null; then
        if command -v yq &> /dev/null; then
            content=$(yq -r '.payload[]' "$file" 2>/dev/null || \
                     yq -r '.rules[]' "$file" 2>/dev/null || \
                     echo "")
        fi
    fi

    if [[ -z "$content" ]]; then
        content=$(cat "$file")
    fi

    echo "$content"
}

save_group() {
    local name="$1"
    local temp_file="$2"

    if [[ ! -s "$temp_file" ]]; then
        echo "⚠️ 警告：分组 $name 没有规则"
        return 1
    fi

    local output_file="$output_dir/${name}.txt"
    local mrs_file="$output_dir/${name}.mrs"

    local temp_content
    temp_content=$(mktemp)

    sort -u "$temp_file" > "$temp_content"
    local rule_count
    rule_count=$(wc -l < "$temp_content")

    local changed=false

    if [[ -f "$output_file" ]]; then
        local existing_content
        existing_content=$(tail -n +5 "$output_file" | sort -u)

        if [[ "$existing_content" == "$(cat "$temp_content")" ]]; then
            echo "⏭️ 分组 $name 无变化"
            changed=false
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

    # ✅ 仅当有变化才更新 TXT（避免无意义 commit）
    if [[ "$changed" == true ]]; then
        {
            echo "# Merged RuleSet for $name"
            echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "# Total Rules: $rule_count"
            echo ""
            cat "$temp_content"
        } > "$output_file"

        echo "✅ TXT 已更新：$output_file ($rule_count 条)"
    else
        echo "⏭️ TXT 无变化，跳过写入"
    fi

    # ==============================
    # ✅ MRS 生成逻辑（关键修复）
    # ==============================
    if command -v mihomo &> /dev/null; then
        if [[ "$changed" == true || ! -f "$mrs_file" ]]; then
            echo "⚙️ 生成 MRS：$name"

            if mihomo convert-ruleset text "$output_file" "$mrs_file" 2>/dev/null; then
                echo "📦 MRS 已生成：$mrs_file"
            else
                echo "⚠️ MRS 生成失败：$name"
            fi
        else
            echo "⏭️ TXT 无变化且 MRS 已存在，跳过"
        fi
    else
        echo "⚠️ 未检测到 mihomo，跳过 MRS 生成"
    fi

    total_rules=$((total_rules + rule_count))

    rm -f "$temp_content"
    return 0
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

    if ! curl -s -L --fail --retry 3 --connect-timeout 30 --max-time 300 "$remote_url" -o "$temp_file"; then
        echo "⚠️ 下载失败：$remote_url"
        continue
    fi

    file_size=$(wc -c < "$temp_file")
    if [[ "$file_size" -lt 100 ]]; then
        echo "⚠️ 文件过小 ($file_size 字节)，跳过"
        rm -f "$temp_file"
        continue
    fi

    rules=$(extract_rules "$temp_file")

    if [[ -z "$rules" ]]; then
        echo "❌ 无法提取规则：$name"
        rm -f "$temp_file"
        continue
    fi

    rule_count=$(echo "$rules" | grep -c '.' || echo 0)
    echo "📊 原始规则：$rule_count 条"

    echo "$rules" | \
      sed 's/，/,/g' | \
      sed 's/^[-•*] *//' | \
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
      sed '/^$/d' | \
      sed '/^#/d' | \
      sed '/7h1s_rul35et_i5_mad3_by_5ukk4w/d' | \
      sed 's/ *, */,/g' | \
      sed -E 's/^\+\.([a-zA-Z0-9.-]+)$/DOMAIN-SUFFIX,\1/' | \
      sed -E 's/^\*\.([a-zA-Z0-9.-]+)$/DOMAIN-SUFFIX,\1/' | \
      sed -E '/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}$/s/^/DOMAIN,/' | \
      sed -E '/^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|PROCESS-NAME),/!s/ *, */,/g' \
      >> "$temp_group_file" || true

    rm -f "$temp_file"

done < "$source_list"

if [[ -n "$group_name" ]]; then
    save_group "$group_name" "$temp_group_file" || true
fi

echo ""
echo "🎉 所有规则集生成完成！"
echo "📈 总计生成：$total_rules 条规则"

if [[ "$has_changes" == "true" ]]; then
    echo "📢 检测到变化，需要提交"
else
    echo "📢 无变化，无需提交"
fi
