
#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================
# 基础配置
# ==============================

source_list="./ruleset_sources"
output_dir="./ruleset_txt"

group_name=""
group_raw_count=0
has_changes=false

temp_file=$(mktemp)
download_tmp=""

mkdir -p "$output_dir"

cleanup() {
    rm -f "$temp_file"
    [[ -n "$download_tmp" ]] && rm -f "$download_tmp"
}

trap cleanup EXIT

# ==============================
# 日志输出
# ==============================

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# ==============================
# 规则清洗
# ==============================

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

# ==============================
# 下载规则
# ==============================

download_rules() {
    local url="$1"
    local status
    local curl_error

    download_tmp=$(mktemp)

    log "⬇️ 下载：$url"

    # 使用较通用的浏览器请求头
    if status=$(curl \
        --silent \
        --show-error \
        --location \
        --fail \
        --compressed \
        --http1.1 \
        --retry 4 \
        --retry-delay 3 \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 120 \
        --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36" \
        --header "Accept: text/plain, text/*, */*" \
        --header "Cache-Control: no-cache" \
        --output "$download_tmp" \
        --write-out '%{http_code}' \
        "$url" 2>&1); then

        :
    else
        curl_error="$status"
        log "❌ 下载失败：$url"
        log "   curl 错误：$curl_error"

        rm -f "$download_tmp"
        download_tmp=""
        return 1
    fi

    log "   HTTP 状态码：$status"

    if [[ "$status" != "200" ]]; then
        log "❌ HTTP 请求异常"
        rm -f "$download_tmp"
        download_tmp=""
        return 1
    fi

    local file_size
    file_size=$(wc -c < "$download_tmp")

    if (( file_size < 50 )); then
        log "❌ 文件过小：${file_size} 字节"
        rm -f "$download_tmp"
        download_tmp=""
        return 1
    fi

    # 防止将 Cloudflare 错误页面误当成规则
    if head -c 4096 "$download_tmp" |
        grep -Eiq '<!DOCTYPE[[:space:]]+html|<html([[:space:]>])'; then

        log "❌ 返回内容是 HTML 页面，而不是规则文件"

        log "   页面内容："
        head -c 300 "$download_tmp" || true
        echo

        rm -f "$download_tmp"
        download_tmp=""
        return 1
    fi

    log "✅ 下载成功：${file_size} 字节"

    return 0
}

# ==============================
# 保存分组
# ==============================

save_group() {
    local name="$1"
    local input="$2"
    local raw_count="$3"

    [[ ! -s "$input" ]] && return 1

    # 防止分组名称影响输出路径
    local safe_name
    safe_name=$(printf '%s' "$name" |
        tr -cd '[:alnum:]_.-')

    [[ -z "$safe_name" ]] && safe_name="unnamed"

    local output="$output_dir/${safe_name}.txt"
    local sorted
    local output_tmp

    sorted=$(mktemp)
    output_tmp=$(mktemp "$output_dir/.${safe_name}.XXXXXX")

    # 统计清洗后的有效行数
    local valid_count
    valid_count=$(wc -l < "$input")

    # 被过滤掉的行数
    local filtered_count=$((raw_count - valid_count))

    # 排序并去重
    if ! LC_ALL=C sort -u "$input" > "$sorted"; then
        log "❌ 排序失败：$name"
        rm -f "$sorted" "$output_tmp"
        return 1
    fi

    # 最终规则数量
    local final_count
    final_count=$(wc -l < "$sorted")

    # 重复规则数量
    local dedup_count=$((valid_count - final_count))

    # 检查是否发生变化
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

    # 生成文件
    {
        echo "# Merged RuleSet for $name"
        echo "# Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Total Rules: $final_count"
        echo ""
        cat "$sorted"
    } > "$output_tmp"

    # 原子替换，避免文件写入中断
    mv -f "$output_tmp" "$output"

    rm -f "$sorted"

    log "✅ $name：生成完成"

    echo "   原始：$raw_count 行"
    echo "   清洗：$filtered_count 行"
    echo "   去重：$dedup_count 条"
    echo "   最终：$final_count 条"
}

# ==============================
# 主程序
# ==============================

if [[ ! -f "$source_list" ]]; then
    log "❌ 找不到规则源文件：$source_list"
    exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do

    # 去除首尾空白
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # 忽略空行和注释
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # 识别分组
    if [[ "$line" =~ ^\[.*\]$ ]]; then

        if [[ -n "$group_name" ]]; then
            save_group "$group_name" "$temp_file" "$group_raw_count" || true
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

    # 没有分组时使用默认分组
    [[ -z "$group_name" ]] && group_name="default"

    url="$line"

    # 下载
    if ! download_rules "$url"; then
        continue
    fi

    # 统计原始行数
    rule_count=$(awk 'END {print NR}' "$download_tmp")

    log "📊 原始行数：$rule_count"

    group_raw_count=$((group_raw_count + rule_count))

    # 清洗规则
    if ! process_rules < "$download_tmp" >> "$temp_file"; then
        log "❌ 规则清洗失败：$url"
    fi

    rm -f "$download_tmp"
    download_tmp=""

done < "$source_list"

# 保存最后一个分组
if [[ -n "$group_name" ]]; then
    save_group "$group_name" "$temp_file" "$group_raw_count" || true
fi

# ==============================
# 执行结果
# ==============================

echo
echo "═══════════════════════════════════"
echo "所有规则集处理完成"
echo "═══════════════════════════════════"

if [[ "$has_changes" == "true" ]]; then
    log "✅ 检测到规则变化，需要提交"
else
    log "⏭️ 无变化，无需提交"
fi
