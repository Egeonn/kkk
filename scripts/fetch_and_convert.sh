#!/bin/bash

source_list="ruleset_sources.txt"
output_dir="ruleset_txt"

mkdir -p "$output_dir"

while IFS= read -r remote_url; do
    [[ -z "$remote_url" ]] && continue

    base=$(basename "$remote_url")
    name="${base%.*}"

    temp_file="${name}_remote.yaml"
    output_file="$output_dir/$name.txt"

    echo "处理规则集：$name"

    curl -s -L "$remote_url" -o "$temp_file"

    # 生成无引号的 payload 内容
    new_payload=$(
      yq -r '.payload[]' "$temp_file" | \
      sed 's/^- *//' | \
      sed 's/#.*//' | \
      sed 's/ //g' | \
      sed '/^$/d'
    )
    new_hash=$(echo "$new_payload" | md5sum | cut -d' ' -f1)

    # 检查是否变化
    if [ -f "$output_file" ]; then
        old_hash=$(grep -v '^#' "$output_file" | md5sum | cut -d' ' -f1)
        if [ "$old_hash" = "$new_hash" ]; then
            echo "→ $name 无变化，跳过"
            continue
        fi
    fi

    # 写入新规则
    echo "# RuleSet generated from remote payload" > "$output_file"
    echo "# Source: $remote_url" >> "$output_file"
    echo "# Generated at $(date)" >> "$output_file"
    echo "" >> "$output_file"

    echo "$new_payload" | sort -u >> "$output_file"

    echo "→ $name 转换完成"

done < "$source_list"
