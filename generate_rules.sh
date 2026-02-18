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
total_dedup=0

cleanup() {
    rm -f "$temp_group_file"
    rm -f *_remote.* 2>/dev/null || true
}
trap cleanup EXIT

# 判断文件类型并提取规则
extract_rules() {
    local file="$1"
    local content=""
    
    # 检查是否是 YAML 格式
    if grep -qE '^payload:|^rules:' "$file" 2>/dev/null; then
        if command -v yq &> /dev/null; then
            content=$(yq -r '.payload[]' "$file" 2>/dev/null || \
                     yq -r '.rules[]' "$file" 2>/dev/null || \
                     echo "")
        fi
    fi
    
    # 如果是空或没有 yq，按纯文本处理
    if [[ -z "$content" ]]; then
        content=$(cat "$file")
    fi
    
    echo "$content"
}

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    line=$(echo "$line" | xargs)
    [[ -z "$line" ]] && continue

    # 判断是否是分组标记
    if [[ "$line" == \[*\] ]]; then
        if [[ -n "$group_name" ]]; then
            output_file="$output_dir/${group_name}.txt"
            if [[ -s "$temp_group_file" ]]; then
                # 去重统计
                raw_count=$(wc -l < "$temp_group_file")
                rule_count=$(sort -u "$temp_group_file" | wc -l)
                dedup_count=$((raw_count - rule_count))
                
                total_rules=$((total_rules + rule_count))
                total_dedup=$((total_dedup + dedup_count))
                
                {
                    echo "# Merged RuleSet for $group_name"
                    echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
                    echo "# Total Rules: $rule_count"
                    if [[ "$dedup_count" -gt 0 ]]; then
                        echo "# Duplicates Removed: $dedup_count"
                    fi
                    echo ""
                    sort -u "$temp_group_file"
                } > "$output_file"
                
                if [[ "$dedup_count" -gt 0 ]]; then
                    echo "✅ 分组 $group_name 已生成：$rule_count 条规则 (去重 $dedup_count 条)"
                else
                    echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
                fi
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

    if ! curl -s -L --fail --retry 3 "$remote_url" -o "$temp_file"; then
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

    rule_count=$(echo "$rules" | wc -l)
    echo "  📊 原始规则：$rule_count 条"

    # ✅ 增强版规则清理（修复中文逗号问题）
    echo "$rules" | \
      # 1. 中文全角逗号 → 英文半角逗号
      sed 's/，/,/g' | \
      # 2. 中文全角空格 → 英文半角空格
      sed 's/ / /g' | \
      # 3. 移除 YAML 列表前缀 (- 或 •)
      sed 's/^[-•*] *//' | \
      # 4. 移除行内注释
      sed 's/#.*//' | \
      # 5. 移除逗号前后所有空格（关键修复！）
      sed 's/ *, */,/g' | \
      # 6. 移除行首行尾空格
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
      # 7. 删除空行
      sed '/^$/d' | \
      # 8. 移除水印规则
      grep -v '^DOMAIN,7h1s_rul35et_i5_mad3_by_5ukk4w-ruleset.skk.moe$' \
      >> "$temp_group_file" || true

    rm -f "$temp_file"
done < "$source_list"

# 处理最后一组
if [[ -n "$group_name" && -s "$temp_group_file" ]]; then
    output_file="$output_dir/${group_name}.txt"
    raw_count=$(wc -l < "$temp_group_file")
    rule_count=$(sort -u "$temp_group_file" | wc -l)
    dedup_count=$((raw_count - rule_count))
    
    total_rules=$((total_rules + rule_count))
    total_dedup=$((total_dedup + dedup_count))
    
    {
        echo "# Merged RuleSet for $group_name"
        echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Total Rules: $rule_count"
        if [[ "$dedup_count" -gt 0 ]]; then
            echo "# Duplicates Removed: $dedup_count"
        fi
        echo ""
        sort -u "$temp_group_file"
    } > "$output_file"
    
    if [[ "$dedup_count" -gt 0 ]]; then
        echo "✅ 分组 $group_name 已生成：$rule_count 条规则 (去重 $dedup_count 条)"
    else
        echo "✅ 分组 $group_name 已生成：$rule_count 条规则"
    fi
elif [[ -n "$group_name" ]]; then
    echo "⚠️ 警告：分组 $group_name 没有规则，跳过生成"
fi

echo ""
echo "🎉 所有规则集生成完成！"
echo "📈 总计生成：$total_rules 条规则"
if [[ "$total_dedup" -gt 0 ]]; then
    echo "🗑️ 总计去重：$total_dedup 条重复规则"
fi
