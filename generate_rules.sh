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
has_changes=false  # ✅ 新增：跟踪是否有变化

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

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    line=$(echo "$line" | xargs)
    [[ -z "$line" ]] && continue

    if [[ "$line" == \[*\] ]]; then
        if [[ -n "$group_name" ]]; then
            output_file="$output_dir/${group_name}.txt"
            if [[ -s "$temp_group_file" ]]; then
                rule_count=$(sort -u "$temp_group_file" | wc -l)
                total_rules=$((total_rules + rule_count))
                
                # ✅ 生成临时文件（不含时间戳）用于比较
                temp_content=$(mktemp)
                sort -u "$temp_group_file" > "$temp_content"
                
                # ✅ 比较规则内容是否变化（忽略头部注释）
                if [[ -f "$output_file" ]]; then
                    # 提取现有文件的规则内容（跳过前 4 行注释）
                    existing_content=$(tail -n +5 "$output_file" | sort -u)
                    new_content=$(cat "$temp_content")
                    
                    if [[ "$existing_content" == "$new_content" ]]; then
                        echo "⏭️ 分组 $group_name 无变化，跳过"
                        rm -f "$temp_content"
                        # 恢复原文件的时间戳
                        continue
                    else
                        echo "📝 分组 $group_name 有更新"
                        has_changes=true
                    fi
                else
                    echo "📝 分组 $group_name 首次生成"
                    has_changes=true
                fi
                
                # 生成最终文件（含时间戳）
                {
                    echo "# Merged RuleSet for $group_name"
                    echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
                    echo "# Total Rules: $rule_count"
                    echo ""
                    cat "$temp_content"
                } > "$output_file"
                
                rm -f "$temp_content"
                echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
            else
                echo "⚠️ 警告：分组 $group_name 没有规则，跳过生成"
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
    temp_file="${name}_remote.txt"

    echo "⬇️ 下载：$name"

    if ! curl -s -L --fail --retry 3 --connect-timeout 30 --max-time 300 "$remote_url" -o "$temp_file"; then
        echo "⚠️ 下载失败：$remote_url"
        continue
    fi

    file_size=$(wc -c < "$temp_file")
    if [[ "$file_size" -lt 100 ]]; then
        echo "  ⚠️ 文件过小 ($file_size 字节)，可能下载失败"
        rm -f "$temp_file"
        continue
    fi

    rules=$(extract_rules "$temp_file")
    
    if [[ -z "$rules" ]]; then
        echo "  ❌ 无法提取规则：$name"
        rm -f "$temp_file"
        continue
    fi

    rule_count=$(echo "$rules" | grep -c '.' || echo 0)
    echo "  📊 原始规则：$rule_count 条"

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

# 处理最后一组
if [[ -n "$group_name" && -s "$temp_group_file" ]]; then
    output_file="$output_dir/${group_name}.txt"
    rule_count=$(sort -u "$temp_group_file" | wc -l)
    total_rules=$((total_rules + rule_count))
    
    temp_content=$(mktemp)
    sort -u "$temp_group_file" > "$temp_content"
    
    if [[ -f "$output_file" ]]; then
        existing_content=$(tail -n +5 "$output_file" | sort -u)
        new_content=$(cat "$temp_content")
        
        if [[ "$existing_content" == "$new_content" ]]; then
            echo "⏭️ 分组 $group_name 无变化，跳过"
            rm -f "$temp_content"
        else
            echo "📝 分组 $group_name 有更新"
            has_changes=true
            {
                echo "# Merged RuleSet for $group_name"
                echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
                echo "# Total Rules: $rule_count"
                echo ""
                cat "$temp_content"
            } > "$output_file"
            rm -f "$temp_content"
            echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
        fi
    else
        echo "📝 分组 $group_name 首次生成"
        has_changes=true
        {
            echo "# Merged RuleSet for $group_name"
            echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo "# Total Rules: $rule_count"
            echo ""
            cat "$temp_content"
        } > "$output_file"
        rm -f "$temp_content"
        echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
    fi
elif [[ -n "$group_name" ]]; then
    echo "⚠️ 警告：分组 $group_name 没有规则，跳过生成"
fi

echo ""
echo "🎉 所有规则集生成完成！"
echo "📈 总计生成：$total_rules 条规则"

# ✅ 输出是否有变化（供 workflow 使用）
if [[ "$has_changes" == "true" ]]; then
    echo "CHANGES_DETECTED=true" >> $GITHUB_ENV 2>/dev/null || true
    echo "📢 检测到变化，需要提交"
    exit 0
else
    echo "CHANGES_DETECTED=false" >> $GITHUB_ENV 2>/dev/null || true
    echo "📢 无变化，无需提交"
    exit 0
fi
