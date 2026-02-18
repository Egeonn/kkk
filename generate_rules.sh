#!/bin/bash

set -euo pipefail

source_list="ruleset_sources"
output_dir="ruleset_txt"

# 检查依赖
if ! command -v yq &> /dev/null; then
    echo "❌ 错误：未找到 yq 命令"
    exit 1
fi

if [[ ! -f "$source_list" ]]; then
    echo "❌ 错误：找不到 $source_list 文件"
    exit 1
fi

mkdir -p "$output_dir"

group_name=""
temp_group_file=$(mktemp)

cleanup() {
    rm -f "$temp_group_file"
    rm -f *_remote.yaml 2>/dev/null || true
}
trap cleanup EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    line=$(echo "$line" | xargs)
    [[ -z "$line" ]] && continue

    # 判断是否是分组标记
    if [[ "$line" == \[*\] ]]; then
        if [[ -n "$group_name" ]]; then
            output_file="$output_dir/${group_name}.txt"
            if [[ -s "$temp_group_file" ]]; then
                # ✅ 统计规则数量
                rule_count=$(sort -u "$temp_group_file" | wc -l)
                
                {
                    echo "# Merged RuleSet for $group_name"
                    echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
                    echo "# Total Rules: $rule_count"
                    echo ""
                    sort -u "$temp_group_file"
                } > "$output_file"
                
                echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
            fi
            > "$temp_group_file"
        fi
        group_name="${line#[}"
        group_name="${group_name%]}"
        group_name=$(echo "$group_name" | xargs)
        continue
    fi

    remote_url="$line"
    clean_url="${remote_url%%\?*}"
    base=$(basename "$clean_url")
    name="${base%.*}"
    temp_file="${name}_remote.yaml"

    echo "⬇️ 下载：$name"

    if ! curl -s -L --fail --retry 3 "$remote_url" -o "$temp_file"; then
        echo "⚠️ 下载失败：$remote_url"
        continue
    fi

    yq -r '.payload[]' "$temp_file" 2>/dev/null | \
      sed 's/^- *//' | \
      sed 's/#.*//' | \
      sed 's/ //g' | \
      sed '/^$/d' | \
      grep -v '^DOMAIN,7h1s_rul35et_i5_mad3_by_5ukk4w-ruleset.skk.moe$' \
      >> "$temp_group_file" || true

    rm -f "$temp_file"
done < "$source_list"

# 处理最后一组
if [[ -n "$group_name" && -s "$temp_group_file" ]]; then
    output_file="$output_dir/${group_name}.txt"
    # ✅ 统计规则数量
    rule_count=$(sort -u "$temp_group_file" | wc -l)
    
    {
        echo "# Merged RuleSet for $group_name"
        echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Total Rules: $rule_count"
        echo ""
        sort -u "$temp_group_file"
    } > "$output_file"
    
    echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
fi

echo "🎉 所有规则集生成完成！"
