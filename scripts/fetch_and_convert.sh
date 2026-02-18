#!/bin/bash

source_list="ruleset_sources"
output_dir="ruleset_txt"

mkdir -p "$output_dir"

group_name=""
temp_all=""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # 判断是否是分组标记，例如 [666]
    if [[ "$line" =~ ^

\[[^]]+\]

$ ]]; then
        # 如果已有分组，先输出结果
        if [[ -n "$group_name" && -n "$temp_all" ]]; then
            output_file="$output_dir/${group_name}.txt"
            echo "# Merged RuleSet for $group_name" > "$output_file"
            echo "# Generated at $(date)" >> "$output_file"
            echo "" >> "$output_file"
            sort -u <<< "$temp_all" >> "$output_file"
            echo "→ 分组 $group_name 已生成：$output_file"
        fi
        # 开始新分组
        group_name="${line#[}"
        group_name="${group_name%]}"
        temp_all=""
        continue
    fi

    remote_url="$line"
    base=$(basename "$remote_url")
    name="${base%.*}"
    temp_file="${name}_remote.yaml"

    echo "下载规则集：$name"

    curl -s -L "$remote_url" -o "$temp_file"

    rules=$(yq -r '.payload[]' "$temp_file" | \
      sed 's/^- *//' | \
      sed 's/#.*//' | \
      sed 's/ //g' | \
      sed '/^$/d' | \
      grep -v '^DOMAIN,7h1s_rul35et_i5_mad3_by_5ukk4w-ruleset.skk.moe$')

    temp_all+=$'\n'"$rules"

done < "$source_list"

# 最后一个分组输出
if [[ -n "$group_name" && -n "$temp_all" ]]; then
    output_file="$output_dir/${group_name}.txt"
    echo "# Merged RuleSet for $group_name" > "$output_file"
    echo "# Generated at $(date)" >> "$output_file"
    echo "" >> "$output_file"
    sort -u <<< "$temp_all" >> "$output_file"
    echo "→ 分组 $group_name 已生成：$output_file"
fi
