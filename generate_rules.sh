
#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================
# 基础配置
# ==========================================

source_list="./ruleset_sources"
output_dir="./ruleset_txt"

group_name=""
group_raw_count=0

has_changes=false
failed_downloads=0
failed_groups=0
successful_downloads=0

temp_file=$(mktemp)
download_tmp=""

mkdir -p "$output_dir"

# ==========================================
# 清理临时文件
# ==========================================

cleanup() {
    rm -f "$temp_file"

    if [[ -n "$download_tmp" ]]; then
        rm -f "$download_tmp"
    }
}

trap cleanup EXIT

# ==========================================
# 日志
# ==========================================

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# ==========================================
# 检查配置文件
# ==========================================

if [[ ! -f "$source_list" ]]; then
    log "❌ 找不到规则源文件：$source_list"
    exit 1
fi

# ==========================================
# 规则清洗
# ==========================================


process_rules() {
    LC_ALL=C sed -E \
        -e '1s/^\xef\xbb\xbf//' \
        -e 's/\r$//' \
        -e 's/，/,/g' \
        -e 's/[[:space:]]+#.*$//' \
        -e 's/^[[:space:]]+//' \
        -e 's/[[:space:]]+$//' \
        -e '/^#/d' \
        -e '/^$/d' \
        -e '/^[#=*_-]+$/d' \
        -e '/^(payload|rules):[[:space:]]*$/d' \
        -e 's/^[•*-][[:space:]]+//' \
        -e "s/^['\"]//; s/['\"]$//" \
        -e '/^DOMAIN-REGEX,/d' \
        -e 's/[[:space:]]*,[[:space:]]*/,/g' \
        -e 's/^\+\.(.+)$/DOMAIN-SUFFIX,\1/' \
        -e 's/^\.(.+)$/DOMAIN-SUFFIX,\1/' \
        -e '/^[a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,}$/s/^/DOMAIN,/' \
        -e '/^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/s/^/IP-CIDR,/' \
        -e '/^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(\/[0-9]{1,3})?$/s/^/IP-CIDR6,/' \
        -e '/(^|,)skk\.moe$/d'
}


# ==========================================
# 下载规则
# ==========================================

download_rules() {

    local url="$1"

    local status=""
    local curl_rc=0
    local attempt

    local headers
    local errors

    download_tmp=$(mktemp)

    headers=$(mktemp)
    errors=$(mktemp)

    # 明确标识自动化客户端
    local user_agent="RulesetUpdater/1.0 (GitHub Actions; +https://github.com/)"

    for attempt in 1 2 3; do

        : > "$download_tmp"
        : > "$headers"
        : > "$errors"

        curl_rc=0

        log "⬇️ 下载：$url（尝试 $attempt/3）"

        status=$(curl \
            --silent \
            --show-error \
            --location \
            --compressed \
            --connect-timeout 15 \
            --max-time 120 \
            --retry 0 \
            --user-agent "$user_agent" \
            --header "Accept: text/plain, */*" \
            --header "Cache-Control: no-cache" \
            --dump-header "$headers" \
            --output "$download_tmp" \
            --write-out '%{http_code}' \
            "$url" 2>"$errors") || curl_rc=$?

        if (( curl_rc != 0 )); then

            log "⚠️ curl 连接失败，退出码：$curl_rc"

            if [[ -s "$errors" ]]; then
                cat "$errors"
            fi

            status=""
        fi

        # ==================================
        # 下载成功
        # ==================================

        if [[ "$status" == "200" ]] && [[ -s "$download_tmp" ]]; then

            # 检查 HTML 错误页面
            if head -c 4096 "$download_tmp" |
                grep -Eiq '<!DOCTYPE[[:space:]]+html|<html([[:space:]>])'; then

                log "❌ 返回 HTML 页面，而不是规则文件"

                head -c 500 "$download_tmp" || true
                echo

                rm -f "$download_tmp" "$headers" "$errors"
                download_tmp=""

                return 1
            fi

            # 检查文件大小
            local file_size

            file_size=$(wc -c < "$download_tmp")

            if (( file_size < 50 )); then

                log "❌ 文件过小：$file_size 字节"

                rm -f "$download_tmp" "$headers" "$errors"
                download_tmp=""

                return 1
            fi

            log "✅ 下载成功：$file_size 字节"

            rm -f "$headers" "$errors"

            return 0
        fi

        # ==================================
        # HTTP 403：重点诊断 Cloudflare
        # ==================================

        if [[ "$status" == "403" ]]; then

            log "❌ HTTP 403：服务器拒绝访问"

            local ray_id

            ray_id=$(awk '
                BEGIN { IGNORECASE=1 }
                /^cf-ray:/ {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    gsub(/\r/, "")
                    print
                }
            ' "$headers" | tail -n 1)

            if [[ -n "$ray_id" ]]; then
                log "Cloudflare Ray ID：$ray_id"
            fi

            if grep -Eiq 'error code: 1010|error 1010' "$download_tmp"; then

                log "⚠️ Cloudflare Error 1010：Browser Integrity Check"

            elif grep -Eiq 'error code: 1020|error 1020' "$download_tmp"; then

                log "⚠️ Cloudflare Error 1020：Firewall Rule"

            else

                log "⚠️ 未识别具体拦截类型，请检查响应信息"

            fi

            log "响应头："

            grep -iE \
                '^(server|cf-ray|cf-mitigated|content-type|retry-after):' \
                "$headers" || true

            log "响应内容："

            head -c 500 "$download_tmp" || true
            echo

            log "建议检查 Cloudflare Security Events"

            rm -f "$download_tmp" "$headers" "$errors"
            download_tmp=""

            return 1
        fi

        # ==================================
        # HTTP 429 / 5xx：有限重试
        # ==================================

        if [[ "$status" =~ ^(429|5[0-9][0-9])$ ]]; then

            if (( attempt < 3 )); then

                local wait_time=$((attempt * 5))

                log "⚠️ HTTP $status，等待 ${wait_time} 秒后重试"

                sleep "$wait_time"

                continue
            fi
        fi

        # ==================================
        # 网络错误：有限重试
        # ==================================

        if [[ -z "$status" ]]; then

            if (( attempt < 3 )); then

                local wait_time=$((attempt * 3))

                log "⚠️ 网络异常，等待 ${wait_time} 秒后重试"

                sleep "$wait_time"

                continue
            fi
        fi

        # ==================================
        # 其他错误
        # ==================================

        log "❌ 下载失败，HTTP 状态码：${status:-未知}"

        if [[ -s "$download_tmp" ]]; then
            head -c 300 "$download_tmp" || true
            echo
        fi

        rm -f "$download_tmp" "$headers" "$errors"
        download_tmp=""

        return 1

    done

    rm -f "$download_tmp" "$headers" "$errors"
    download_tmp=""

    return 1
}

# ==========================================
# 保存规则分组
# ==========================================

save_group() {

    local name="$1"
    local input="$2"
    local raw_count="$3"

    if [[ ! -s "$input" ]]; then

        log "⚠️ $name：没有有效规则，保留原文件"

        failed_groups=$((failed_groups + 1))

        return 1
    fi

    # 清理分组名称，避免路径注入
    local safe_name

    safe_name=$(printf '%s' "$name" | tr -cd '[:alnum:]_.-')

    [[ -z "$safe_name" ]] && safe_name="unnamed"

    local output="$output_dir/${safe_name}.txt"

    local sorted
    local output_tmp

    sorted=$(mktemp)
    output_tmp=$(mktemp "$output_dir/.${safe_name}.XXXXXX")

    # ==================================
    # 统计清洗后的有效行数
    # ==================================

    local valid_count

    valid_count=$(wc -l < "$input")

    local filtered_count

    filtered_count=$((raw_count - valid_count))

    # ==================================
    # 排序和去重
    # ==================================

    if ! LC_ALL=C sort -u "$input" > "$sorted"; then

        log "❌ 排序失败：$name"

        rm -f "$sorted" "$output_tmp"

        failed_groups=$((failed_groups + 1))

        return 1
    fi

    local final_count

    final_count=$(wc -l < "$sorted")

    local dedup_count

    dedup_count=$((valid_count - final_count))

    # ==================================
    # 检查文件是否变化
    # ==================================

    if [[ -f "$output" ]]; then

        if tail -n +5 "$output" |
            LC_ALL=C sort -u |
            cmp -s - "$sorted"; then

            log "⏭️ $name：无变化"

            echo "   原始：$raw_count 行"
            echo "   清洗：$filtered_count 行"
            echo "   去重：$dedup_count 条"
            echo "   最终：$final_count 条"

            rm -f "$sorted" "$output_tmp"

            return 1
        else

            log "📝 $name：检测到更新"

            has_changes=true

        fi

    else

        log "📝 $name：首次生成"

        has_changes=true

    fi

    # ==================================
    # 写入新文件
    # ==================================

    {
        echo "# Merged RuleSet for $name"
        echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Total Rules: $final_count"
        echo ""
        cat "$sorted"

    } > "$output_tmp"

    # 原子替换
    if ! mv -f "$output_tmp" "$output"; then

        log "❌ 文件写入失败：$name"

        rm -f "$sorted" "$output_tmp"

        failed_groups=$((failed_groups + 1))

        return 1
    fi

    rm -f "$sorted"

    log "✅ $name：生成完成"

    echo "   原始：$raw_count 行"
    echo "   清洗：$filtered_count 行"
    echo "   去重：$dedup_count 条"
    echo "   最终：$final_count 条"

    return 0
}

# ==========================================
# 主程序
# ==========================================

while IFS= read -r line || [[ -n "$line" ]]; do

    # 去除首尾空白
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # 忽略空行和注释
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # ======================================
    # 分组识别
    # ======================================

    if [[ "$line" =~ ^\[.*\]$ ]]; then

        if [[ -n "$group_name" ]]; then

            save_group \
                "$group_name" \
                "$temp_file" \
                "$group_raw_count" || true

        fi

        group_name="${line#[}"
        group_name="${group_name%]}"

        : > "$temp_file"

        group_raw_count=0

        echo
        echo "═══════════════════════════════════"

        log "📁 开始分组：$group_name"

        echo "═══════════════════════════════════"

        continue
    fi

    # ======================================
    # 默认分组
    # ======================================

    if [[ -z "$group_name" ]]; then

        group_name="default"

    fi

    url="$line"

    # ======================================
    # 下载
    # ======================================

    if ! download_rules "$url"; then

        failed_downloads=$((failed_downloads + 1))

        continue

    fi

    successful_downloads=$((successful_downloads + 1))

    # ======================================
    # 统计原始行数
    # ======================================

    rule_count=$(awk 'END {print NR}' "$download_tmp")

    log "📊 原始行数：$rule_count"

    group_raw_count=$((group_raw_count + rule_count))

    # ======================================
    # 清洗规则
    # ======================================

    if ! process_rules < "$download_tmp" >> "$temp_file"; then

        log "❌ 规则清洗失败：$url"

        failed_downloads=$((failed_downloads + 1))

    fi

    rm -f "$download_tmp"

    download_tmp=""

done < "$source_list"

# ==========================================
# 保存最后一个分组
# ==========================================

if [[ -n "$group_name" ]]; then

    save_group \
        "$group_name" \
        "$temp_file" \
        "$group_raw_count" || true

fi

# ==========================================
# 最终执行报告
# ==========================================

echo
echo "═══════════════════════════════════"
echo "规则集处理完成"
echo "═══════════════════════════════════"

echo "成功下载：$successful_downloads"
echo "下载或清洗失败：$failed_downloads"
echo "分组生成失败：$failed_groups"

echo "═══════════════════════════════════"

if [[ "$has_changes" == "true" ]]; then

    log "📝 检测到规则变化，需要提交"

else

    log "⏭️ 无变化，无需提交"

fi

# ==========================================
# GitHub Actions 退出状态
# ==========================================

if (( failed_downloads > 0 || failed_groups > 0 )); then

    log "❌ 存在失败项目，请检查日志"

    exit 1

fi

log "✅ 所有任务执行成功"

exit 0
