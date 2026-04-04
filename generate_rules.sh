save_group() {
    local name="$1"
    local temp_file="$2"

    if [[ ! -s "$temp_file" ]]; then
        echo "⚠️ 警告：分组 $name 没有规则"
        return 1
    fi

    local output_file="$output_dir/${name}.txt"
    local mrs_file="$output_dir/${name}.mrs"
    local mrs_input_file
    mrs_input_file=$(mktemp)

    local temp_content
    temp_content=$(mktemp)

    sort -u "$temp_file" > "$temp_content"
    local rule_count
    rule_count=$(wc -l < "$temp_content")

    local changed=false

    # ===== 检查 TXT 是否变化 =====
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

    # ===== 写入完整 TXT（保持兼容）=====
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
    # ✅ 生成 MRS 专用“干净规则”
    # ==============================
    grep -E '^(DOMAIN|DOMAIN-SUFFIX),' "$output_file" | sort -u > "$mrs_input_file"

    local clean_count
    clean_count=$(wc -l < "$mrs_input_file")

    if [[ "$clean_count" -eq 0 ]]; then
        echo "⚠️ 无有效 DOMAIN 规则，跳过 MRS：$name"
        rm -f "$temp_content" "$mrs_input_file"
        return 0
    fi

    echo "🌐 可用于 MRS 的规则：$clean_count 条"

    # ==============================
    # ✅ 生成 MRS（核心）
    # ==============================
    if command -v mihomo &> /dev/null; then
        if [[ "$changed" == true || ! -f "$mrs_file" ]]; then
            echo "⚙️ 生成 MRS：$name"

            if mihomo convert-ruleset text "$mrs_input_file" "$mrs_file"; then
                echo "📦 MRS 已生成：$mrs_file"
            else
                echo "❌ MRS 生成失败：$name"
            fi
        else
            echo "⏭️ TXT 无变化且 MRS 已存在，跳过"
        fi
    else
        echo "⚠️ 未检测到 mihomo，跳过 MRS 生成"
    fi

    total_rules=$((total_rules + rule_count))

    rm -f "$temp_content" "$mrs_input_file"
    return 0
}
