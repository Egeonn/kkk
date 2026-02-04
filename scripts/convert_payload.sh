#!/bin/bash

input_dir="mihomo_ruleset"
output_dir="surge_ruleset"

mkdir -p "$output_dir"

for file in "$input_dir"/*.yaml; do
    name=$(basename "$file" .yaml)
    output="$output_dir/$name.list"

    echo "# Surge RuleSet generated from payload: $name" > "$output"
    echo "# Generated at $(date)" >> "$output"
    echo "" >> "$output"

    # 提取 payload 数组
    yq '.payload[]' "$file" | \
    sed 's/^- *//' | \
    sed 's/#.*//' | \
    sed 's/ //g' | \
    sed '/^$/d' | \
    sort -u >> "$output"
done
