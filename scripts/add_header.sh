#!/bin/bash

output_dir="output"

for file in "$output_dir"/*.list; do
    name=$(basename "$file" .list)
    count=$(grep -v '^#' "$file" | wc -l)

    sed -i "1i # 规则名称: $name" "$file"
    sed -i "2i # 规则统计: $count" "$file"
    sed -i '3a\\' "$file"
done
