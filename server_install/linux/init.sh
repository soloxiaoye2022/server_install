#!/bin/bash

#=============================================================================
# L4D2 Server Manager (L4M)
# Author: Soloxiaoye
# Description: 全平台兼容 (Root/Non-Root/Proot)、多实例管理、CLI/TUI、自启/备份
#=============================================================================

# 0. 环境预检与 Locale 设置
setup_env() {
    # 强制设置 Locale 为 UTF-8，解决中文乱码问题
    if command -v locale >/dev/null 2>&1; then
        if locale -a 2>/dev/null | grep -q "C.UTF-8"; then
            export LANG=C.UTF-8; export LC_ALL=C.UTF-8
        elif locale -a 2>/dev/null | grep -q "zh_CN.UTF-8"; then
            export LANG=zh_CN.UTF-8; export LC_ALL=zh_CN.UTF-8
        elif locale -a 2>/dev/null | grep -q "en_US.UTF-8"; then
            export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
        fi
    else
        export LANG=C.UTF-8; export LC_ALL=C.UTF-8
        M_NO_REPO_ASK_DL="Plugin repo not set or invalid (must contain JS-MODS).\nDownload plugin packages now?"
        M_REPO_AUTO_SET="Auto-selected plugin repo: "
        M_REPO_SELECT_TITLE="Multiple Valid Packages Found"
        M_REPO_SELECT_MSG="Please select one as current repo:"
        M_NO_VALID_PKG="${RED}No valid package found (must contain JS-MODS).${NC}"
        M_REPO_INVALID_HAS_LOCAL="Plugin repo invalid, but found local packages with JS-MODS.\nGo to select one?"
        M_REPO_INVALID_NO_LOCAL="Plugin repo invalid and no local packages found.\nGo to download?"
        M_GO_SELECT_REPO="Select Repo"
        M_GO_DOWNLOAD="Download Packages"
        M_REPO_STILL_INVALID="Repo still invalid, cannot manage plugins."
    fi
}
setup_env

#=============================================================================
# 1. 全局配置与常量
#=============================================================================

# 路径定义
SYSTEM_INSTALL_DIR="/usr/local/l4d2_manager"
USER_INSTALL_DIR="$HOME/.l4d2_manager"
SYSTEM_BIN="/usr/bin/l4m"
USER_BIN="$HOME/bin/l4m"

# 智能探测运行环境
if [[ "$0" == "$SYSTEM_INSTALL_DIR/l4m" ]] || [[ -L "$0" && "$(readlink -f "$0")" == "$SYSTEM_INSTALL_DIR/l4m" ]]; then
    MANAGER_ROOT="$SYSTEM_INSTALL_DIR"
    INSTALL_TYPE="system"
elif [[ "$0" == "$USER_INSTALL_DIR/l4m" ]] || [[ -L "$0" && "$(readlink -f "$0")" == "$USER_INSTALL_DIR/l4m" ]]; then
    MANAGER_ROOT="$USER_INSTALL_DIR"
    INSTALL_TYPE="user"
else
    if [[ "$0" == *"bash"* ]] || [[ "$0" == *"/fd/"* ]]; then
        MANAGER_ROOT="/tmp/l4m_install_temp"
        mkdir -p "$MANAGER_ROOT" 2>/dev/null || MANAGER_ROOT="$HOME/.cache/l4m_temp"
        mkdir -p "$MANAGER_ROOT"
    else
        MANAGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    INSTALL_TYPE="temp"
fi

# 确定最终使用的配置路径
if [[ "$INSTALL_TYPE" != "temp" ]]; then
    FINAL_ROOT="$MANAGER_ROOT"
else
    # 临时模式下，为了避免未安装前污染系统目录，先将根目录指向临时目录
    # 在执行 install_smart 时会将配置文件复制到真实系统目录
    FINAL_ROOT="$MANAGER_ROOT"
fi

# 数据文件路径
DATA_FILE="${FINAL_ROOT}/servers.dat"
PLUGIN_CONFIG="${FINAL_ROOT}/plugin_config.dat"
CONFIG_FILE="${FINAL_ROOT}/config.dat"
STEAMCMD_DIR="${FINAL_ROOT}/steamcmd_common"
SERVER_CACHE_DIR="${FINAL_ROOT}/server_cache"
TRAFFIC_DIR="${FINAL_ROOT}/traffic_logs"
TRAFFIC_BACKEND="auto"
BACKUP_DIR="${FINAL_ROOT}/backups"
DEFAULT_APPID="222860"
L4M_VERSION="0.1.1"
REMOTE_VERSION_CACHE="${FINAL_ROOT}/remote_version.dat"

# 默认插件库目录
if [ -f "$PLUGIN_CONFIG" ]; then 
    JS_MODS_DIR=$(cat "$PLUGIN_CONFIG")
else
    if [ "$EUID" -eq 0 ]; then JS_MODS_DIR="/root/L4D2_Plugins"; else JS_MODS_DIR="$HOME/L4D2_Plugins"; fi
fi
mkdir -p "$JS_MODS_DIR"

# 链接清单定义
LINK_DIRS=(
    "left4dead2/bin"
    "left4dead2/expressions"
    "left4dead2/gfx"
    "left4dead2/maps"
    "left4dead2/materials"
    "left4dead2/reslists"
    "left4dead2/resource"
    "left4dead2/scenes"
    "left4dead2_dlc1"
    "left4dead2_dlc2"
    "left4dead2_dlc3"
    "left4dead2_lv"
    "platform"
    "update"
)

LINK_FILES_ROOT=(
    "left4dead2/gameinfo.txt"
    "left4dead2/glbaseshaders.cfg"
    "left4dead2/lights.rad"
    "left4dead2/mapcycle.txt"
    "left4dead2/maplist.txt"
    "left4dead2/missioncycle.txt"
    "left4dead2/modelsounds.cache"
    "left4dead2/pak01_dir.vpk"
    "left4dead2/program_cache.cfg"
    "left4dead2/steam.inf"
    "left4dead2/whitelist.cfg"
)

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
GREY='\033[90m'
NC='\033[0m'

#=============================================================================
# 2. 工具函数 (Utils)
#=============================================================================

# URL编码函数 (支持中文和特殊字符)
urlencode() {
    # 强制使用 C 语言环境处理字节，避免 UTF-8 字符被错误截断或转码
    local LC_ALL=C
    local string="$1"
    local length="${#string}"
    for (( i = 0; i < length; i++ )); do
        local c="${string:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

# 检查依赖
check_deps() {
    local miss=()
    local req=("tmux" "curl" "wget" "tar" "tree" "sed" "awk" "lsof" "7z" "unzip" "file" "whiptail")
    for c in "${req[@]}"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
    if [ ${#miss[@]} -eq 0 ]; then return 0; fi
    
    echo -e "$M_MISSING_DEPS ${miss[*]}"
    local cmd=""
    if [ -f /etc/debian_version ]; then
        local deb_pkgs="${miss[*]}"
        deb_pkgs=$(echo "$deb_pkgs" | sed 's/7z/p7zip-full/g')
        # 使用 ; 替代 &&，确保即使 update 因个别源报错（如 Release file 缺失），也能尝试继续安装依赖
        cmd="apt-get update -qq; apt-get install -y -qq --fix-missing $deb_pkgs lib32gcc-s1 lib32stdc++6 ca-certificates"
    elif [ -f /etc/redhat-release ]; then
        local rhel_pkgs="${miss[*]}"
        rhel_pkgs=$(echo "$rhel_pkgs" | sed 's/7z/p7zip/g')
        cmd="yum install -y -q $rhel_pkgs glibc.i686 libstdc++.i686"
    fi

    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            echo -e "$M_TRY_SUDO"
            if [ -f /etc/debian_version ]; then sudo dpkg --add-architecture i386 >/dev/null 2>&1; fi
            if sudo bash -c "$cmd"; then echo -e "$M_INSTALL_OK"; return 0; fi
        fi
        if command -v pkg >/dev/null; then pkg install -y "${miss[@]}"; return; fi
        MENU_TITLE="依赖缺失" tui_msgbox "$M_MANUAL_INSTALL sudo $cmd"; return
    fi
    
    if [ -f /etc/debian_version ]; then dpkg --add-architecture i386 >/dev/null 2>&1; fi
    eval "$cmd"
}

# 生成独立更新脚本
generate_updater() {
    local path="$1"
    cat << 'EOF' > "$path"
#!/bin/bash
# L4M 独立更新器
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'

echo -e "${YELLOW}正在启动独立更新...${NC}"

# 定义镜像列表 (与主脚本保持一致)
MIRRORS=(
    "https://ghfast.top"
    "https://jiashu.1win.eu.org"
    "https://j.1win.ggff.net"
    "https://gh-proxy.com"
    "https://gh-proxy.net"
    "DIRECT"
)

target_url="https://raw.githubusercontent.com/soloxiaoye2022/server_install/main/server_install/linux/init.sh"
temp_file="/tmp/l4m_new.sh"
rm -f "$temp_file"

success=false

for m in "${MIRRORS[@]}"; do
    url="$target_url"
    if [ "$m" != "DIRECT" ]; then url="${m}/${target_url}"; fi
    
    echo -e "尝试线路: ${GREEN}$m${NC}"
    if curl -L -f --connect-timeout 10 -m 60 -o "$temp_file" "$url" || wget --no-check-certificate -T 10 -t 2 -O "$temp_file" "$url"; then
        # 校验
        fsize=$(wc -c < "$temp_file" 2>/dev/null || echo 0)
        if grep -q "main()" "$temp_file" && [ "$fsize" -gt 10240 ]; then
            echo -e "${GREEN}下载成功，正在应用更新...${NC}"
            
            # 确定安装位置
            install_path=""
            if [ -f "/usr/local/l4d2_manager/l4m" ]; then install_path="/usr/local/l4d2_manager/l4m"; 
            elif [ -f "$HOME/.l4d2_manager/l4m" ]; then install_path="$HOME/.l4d2_manager/l4m"; fi
            
            if [ -n "$install_path" ]; then
                mv "$temp_file" "$install_path"
                chmod +x "$install_path"
                echo -e "${GREEN}更新完成！请运行 l4m 查看。${NC}"
                success=true
                break
            else
                echo -e "${RED}未找到现有的安装，更新未应用。${NC}"
                rm "$temp_file"
                break
            fi
        else
            echo -e "${RED}校验失败 (文件过小或内容不完整)${NC}"
            rm "$temp_file"
        fi
    else
        echo -e "${RED}连接失败${NC}"
    fi
done

if [ "$success" = false ]; then
    echo -e "${RED}所有线路均更新失败，请检查网络。${NC}"
    exit 1
fi
EOF
    chmod +x "$path"
}

check_port() {
    local port="$1"
    if command -v lsof >/dev/null; then lsof -i ":$port" >/dev/null 2>&1; return $?; fi
    if command -v netstat >/dev/null; then netstat -tuln | grep -q ":$port "; return $?; fi
    (echo > /dev/tcp/127.0.0.1/$port) >/dev/null 2>&1; return $?
}

#=============================================================================
# 3. 网络与下载模块 (Core Network)
#=============================================================================

# 定义镜像源列表
MIRRORS=(
    "https://ghfast.top"
    "https://jiashu.1win.eu.org"
    "https://j.1win.ggff.net"
    "https://gh-proxy.com"
    "https://gh-proxy.net"
    "DIRECT" # 直连作为保底
)
BEST_MIRROR=""

# 测试并选择最佳镜像
select_best_mirror() {
    if [ -n "$BEST_MIRROR" ]; then return; fi
    
    echo -e "${YELLOW}正在优选最佳下载线路...${NC}"
    # 使用一个小文件进行测速，例如 LICENSE
    local target_path="soloxiaoye2022/server_install/main/LICENSE"
    local check_url="https://raw.githubusercontent.com/$target_path"
    
    local best_speed=0
    local best="DIRECT"
    
    # 临时增加 DIRECT 到数组头部进行测试
    local test_mirrors=("DIRECT" "${MIRRORS[@]}")
    # 去重
    local unique_mirrors=($(echo "${test_mirrors[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    for m in "${unique_mirrors[@]}"; do
        local test_target_url=""
        if [ "$m" == "DIRECT" ]; then
            test_target_url="$check_url"
        else
            test_target_url="${m}/${check_url}"
        fi
        
        # 测速: 获取 http_code 和 download_speed (B/s)
        # 只有 HTTP 200 才算成功
        local curl_output=$(curl -L -k --connect-timeout 2 -m 5 -o /dev/null -s -w "%{http_code}:%{speed_download}" "$test_target_url")
        local status=$(echo "$curl_output" | cut -d: -f1)
        local speed=$(echo "$curl_output" | cut -d: -f2 | cut -d. -f1)
        
        if [ "$status" -eq 200 ]; then
            # 格式化速度
            local speed_human=""
            if [ "$speed" -gt 1048576 ]; then
                speed_human="$((speed/1048576)) MB/s"
            elif [ "$speed" -gt 1024 ]; then
                speed_human="$((speed/1024)) KB/s"
            else
                speed_human="$speed B/s"
            fi
            
            echo -e "  [${GREEN}OK${NC}] $m - $speed_human"
            
            if [ "$speed" -gt "$best_speed" ]; then
                best_speed=$speed
                best=$m
            fi
        else
            echo -e "  [${RED}Fail${NC}] $m - (HTTP $status)"
        fi
    done
    
    BEST_MIRROR=$best
    echo -e "${GREEN}==> 选中线路: $BEST_MIRROR${NC}"
}

# 通用下载函数 (带重试和多源切换)
# 参数: $1=GitHub相对路径(user/repo/branch/path), $2=本地保存路径, $3=描述
download_file() {
    local git_path="$1"
    local save_path="$2"
    local desc="$3"
    
    # 鲁棒性处理: 如果传入的 git_path 已经包含了常见的代理前缀，则尝试移除它们
    # 这可以防止双重代理导致的 URL 错误
    # 移除常见代理前缀
    git_path="${git_path#*gh-proxy.com/}"
    git_path="${git_path#*gh-proxy.net/}"
    git_path="${git_path#*ghfast.top/}"
    git_path="${git_path#*jiashu.1win.eu.org/}"
    
    if [[ "$git_path" == *"/https://"* ]]; then
        git_path="${git_path##*/https://}"
        # 恢复 https:// 前缀如果被截断后只是 raw.github...
        if [[ "$git_path" != http* ]]; then git_path="https://$git_path"; fi
    fi
    
    select_best_mirror
    
    echo -e "${CYAN}正在下载: $desc${NC}"
    
    # 准备目标 URL (raw)
    local target_raw_url=""
    local target_media_url="" # 用于 LFS
    
    if [[ "$git_path" == http* ]]; then
        target_raw_url="$git_path"
        # 如果是绝对路径，media URL 难以自动推导，除非解析 GitHub URL
        target_media_url="$git_path" 
    else
        local dir_path=$(dirname "$git_path")
        local filename=$(basename "$git_path")
        local encoded_name=$(urlencode "$filename")
        # 移除 ./ 前缀
        if [[ "$dir_path" == "." ]]; then dir_path=""; else dir_path="${dir_path}/"; fi
        
        target_raw_url="https://raw.githubusercontent.com/${dir_path}${encoded_name}"
        target_media_url="https://media.githubusercontent.com/media/${dir_path}${encoded_name}"
    fi
    
    echo -e "${GREY}  [Debug] Target: $target_raw_url${NC}"

    # 构建尝试列表
    local try_list=("$BEST_MIRROR")
    for m in "${MIRRORS[@]}"; do
        if [ "$m" != "$BEST_MIRROR" ]; then try_list+=("$m"); fi
    done
    
    local success=false
    
    for mirror in "${try_list[@]}"; do
        local current_url=""
        
        # 构造 URL
        if [ "$mirror" == "DIRECT" ]; then
            current_url="$target_raw_url"
        else
            current_url="${mirror}/${target_raw_url}"
        fi
        
        echo -e "${GREY}  [Debug] URL: $current_url${NC}"
        
        # 下载尝试
        local dl_ok=false
        if curl -L -f --retry 2 --connect-timeout 10 -m 600 -# "$current_url" -o "$save_path"; then
            dl_ok=true
        else
            echo -e "${YELLOW}  curl 失败，尝试 wget...${NC}"
            if wget --no-check-certificate -q --show-progress --tries=2 --timeout=10 -O "$save_path" "$current_url"; then
                dl_ok=true
            fi
        fi
        
        if [ "$dl_ok" = true ]; then
            # 1. 检查是否为 LFS 指针 (小文件且包含 oid sha256)
            local fsize=$(wc -c < "$save_path" 2>/dev/null || echo 0)
            if [ "$fsize" -lt 2048 ] && grep -q "oid sha256:" "$save_path"; then
                echo -e "${YELLOW}  检测到 LFS 指针，尝试使用 media 链接...${NC}"
                
                # 构造 media URL
                local media_try_url=""
                if [ "$mirror" == "DIRECT" ]; then
                    media_try_url="$target_media_url"
                else
                    media_try_url="${mirror}/${target_media_url}"
                fi
                echo -e "${GREY}  [LFS Debug] URL: $media_try_url${NC}"
                
                if curl -L -f --retry 2 --connect-timeout 20 -m 1800 -# "$media_try_url" -o "$save_path"; then
                    # 更新文件大小
                    fsize=$(wc -c < "$save_path" 2>/dev/null || echo 0)
                else
                    echo -e "${RED}  LFS 文件下载失败。${NC}"
                    dl_ok=false
                fi
            fi
            
            # 2. 检查是否为错误页面 (HTML)
            if [ "$dl_ok" = true ] && [ "$fsize" -gt 1024 ]; then
                 local is_html=false
                 if command -v file >/dev/null; then
                     local mime=$(file -b --mime-type "$save_path")
                     if [[ "$mime" == text/html* ]]; then is_html=true; fi
                 fi
                 # 简单文本检查
                 if [ "$is_html" = false ] && head -n 1 "$save_path" | grep -qi "<!DOCTYPE html"; then is_html=true; fi
                 
                 if [ "$is_html" = true ]; then
                     echo -e "${YELLOW}  警告: 下载的是 HTML 页面，非有效文件。${NC}"
                     dl_ok=false
                 fi
            fi
            
            # 3. 完整性校验 (可选)
            if [ "$dl_ok" = true ] && [ "$fsize" -gt 1024 ]; then
                if [[ "$save_path" == *.zip ]]; then
                    if command -v unzip >/dev/null && ! unzip -tq "$save_path" >/dev/null 2>&1; then
                         echo -e "${YELLOW}  ZIP 校验失败。${NC}"
                         dl_ok=false
                    fi
                elif [[ "$save_path" == *.7z ]]; then
                    if command -v 7z >/dev/null && ! 7z t "$save_path" >/dev/null 2>&1; then
                         echo -e "${YELLOW}  7z 校验失败。${NC}"
                         dl_ok=false
                    fi
                fi
            fi
            
            if [ "$dl_ok" = true ] && [ "$fsize" -gt 1024 ]; then
                success=true
                break
            else
                rm -f "$save_path"
            fi
        fi
    done
    
    if [ "$success" = true ]; then return 0; else echo -e "${RED}下载失败。${NC}"; return 1; fi
}

# 去除颜色代码函数
strip_colors() {
    # 1. 去除 literal \033 (例如变量定义的颜色)
    # 2. 去除 hex \x1b (真实转义符)
    # 3. 去除可能的 \e
    echo "$1" | sed -r 's/\\033\[[0-9;]*m//g' | sed -r 's/\x1b\[[0-9;]*m//g' | sed -r 's/\\e\[[0-9;]*m//g'
}

#=============================================================================
# 4. TUI 界面框架
#=============================================================================
tui_header() { 
    if command -v whiptail >/dev/null 2>&1; then return; fi
    clear; echo -e "${BLUE}$M_TITLE${NC}\n"; 
}

tui_msgbox() {
    local t="$1"
    
    if command -v whiptail >/dev/null 2>&1; then
        # 移除颜色代码
        local clean_t=$(strip_colors "$t")
        local box_title="${MENU_TITLE:-$M_TITLE}"
        local clean_title=$(strip_colors "$box_title")
        
        # 计算最长行的长度
        local max_line_len=0
        while IFS= read -r line; do
            local len=${#line}
            if [ $len -gt $max_line_len ]; then max_line_len=$len; fi
        done <<< "$clean_t"
        
        # 基础宽度 = 最长行 + 边框填充(大约20)
        local w=$((max_line_len + 20))
        
        # 限制最小/最大宽度
        local term_cols=$(tput cols)
        if [ $w -lt 50 ]; then w=50; fi
        if [ $w -gt $((term_cols - 4)) ]; then w=$((term_cols - 4)); fi
        
        # 自动计算高度
        local line_count=$(echo "$clean_t" | wc -l)
        # 基础高度 = 行数 + 标题栏/按钮栏/边框(大约8)
        local h=$((line_count + 8))
        local term_lines=$(tput lines)
        if [ $h -gt $((term_lines - 4)) ]; then h=$((term_lines - 4)); fi
        
        whiptail --title "$clean_title" --msgbox "$clean_t" $h $w
    else
        tui_header
        echo -e "${YELLOW}$t${NC}"
        echo -e "\n${YELLOW}$M_PRESS_KEY${NC}"
        read -n 1 -s -r
    fi
}

tui_input() {
    local p="$1"; local d="$2"; local v="$3"; local pass="$4"
    
    if command -v whiptail >/dev/null 2>&1; then
        local h=10
        local w=60
        local type="--inputbox"
        if [ "$pass" == "true" ]; then type="--passwordbox"; fi
        
        # 移除颜色代码，防止 whiptail 标题乱码
        local clean_p=$(strip_colors "$p")
        local box_title="${MENU_TITLE:-$M_TITLE}"
        local clean_title=$(strip_colors "$box_title")
        
        local val
        val=$(whiptail --title "$clean_title" "$type" "$clean_p" $h $w "$d" 3>&1 1>&2 2>&3)
        
        if [ $? -eq 0 ]; then
            eval $v=\"\$val\"
            return 0
        else
            eval $v=""
            return 1 # 返回非0表示用户取消
        fi
    fi

    if [ -n "$d" ]; then echo -e "${YELLOW}$p ${GREY}[默认: $d]${NC}"; else echo -e "${YELLOW}$p${NC}"; fi
    if [ "$pass" == "true" ]; then read -s -p "> " i; echo ""; else read -p "> " i; fi
    if [ -z "$i" ] && [ -n "$d" ]; then eval $v="$d"; else eval $v=\"\$i\"; fi
    return 0 # 纯文本模式暂时无法区分取消，默认成功
}

tui_menu() {
    local t="$1"; shift; local opts=("$@"); local sel=0; local tot=${#opts[@]}
    
    if command -v whiptail >/dev/null 2>&1; then
        # 修复: 清理标题中的颜色代码
        local clean_title=$(strip_colors "$t")
        local max_len=${#clean_title}
        
        local args=()
        for ((i=0; i<tot; i++)); do
            # 移除颜色代码
            local clean_opt=$(strip_colors "${opts[i]}")
            # 修复: 移除可能存在的 "1. " 序号前缀
            clean_opt=$(echo "$clean_opt" | sed 's/^[0-9]*[.]\s*//')
            
            # 计算最大长度
            local len=${#clean_opt}
            if [ $len -gt $max_len ]; then max_len=$len; fi
            
            args+=("$((i+1))" "${clean_opt}")
        done
        
        # 基础宽度
        local w=$((max_len + 24))
        local term_cols=$(tput cols)
        local term_lines=$(tput lines)
        
        if [ $w -lt 60 ]; then w=60; fi
        if [ $w -gt $((term_cols - 4)) ]; then w=$((term_cols - 4)); fi
        
        # 高度计算 (更稳健的逻辑)
        # 边框+标题+底部按钮大约需要 8 行
        local border_h=8
        # 预留给终端提示符的空间
        local max_h=$((term_lines - 4))
        if [ $max_h -lt 10 ]; then max_h=$term_lines; fi # 极端情况占满全屏
        
        local h=$max_h
        if [ $h -gt 30 ]; then h=30; fi
        
        # 计算列表高度
        local list_h=$((h - border_h))
        
        # 如果列表高度太小，尝试增加总高度，但不能超过 max_h
        if [ $list_h -lt 5 ]; then 
            list_h=5
            h=$((list_h + border_h))
            if [ $h -gt $max_h ]; then 
                h=$max_h 
                list_h=$((h - border_h))
            fi
        fi
        
        # 如果最终列表高度还是太小(例如终端极小)，whiptail可能会失败，但这已是尽力了
        if [ $list_h -lt 1 ]; then list_h=1; fi

        local box_title="${MENU_TITLE:-$M_TITLE}"
        local clean_box_title=$(strip_colors "$box_title")
        
        local choice
        if choice=$(whiptail --title "$clean_box_title" --menu "$clean_title" $h $w $list_h "${args[@]}" 3>&1 1>&2 2>&3); then
            return $((choice-1))
        else
            # 只有当用户明确取消 (exit 1) 或 ESC (exit 255) 时才返回错误
            # 如果是 whiptail 执行错误 (例如参数不对)，尝试 fallback
            local ret=$?
            if [ $ret -eq 255 ] || [ $ret -eq 1 ]; then
                return 255
            fi
            # 其他错误码 (如 127, 139 等) 则进入 fallback
        fi
    fi

    # Fallback: 纯文本菜单 (当 whiptail 不存在或执行崩溃时)
    tui_header
        echo -e "${CYAN}$t${NC}"
        for ((i=0; i<tot; i++)); do
            echo -e "${GREEN}$((i+1)).${NC} ${opts[i]}"
        done
        echo ""
        local choice
        read -p "Please select [1-$tot]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$tot" ]; then
            return $((choice-1))
        else
            return 255
        fi
}

#=============================================================================
# 5. 核心逻辑：安装与管理
#=============================================================================

install_smart() {
    echo -e "${CYAN}$M_INIT_INSTALL${NC}"
    local target_dir=""
    local link_path=""
    
    if [ "$EUID" -eq 0 ]; then
        target_dir="$SYSTEM_INSTALL_DIR"; link_path="$SYSTEM_BIN"
    else
        target_dir="$USER_INSTALL_DIR"; link_path="$USER_BIN"
    fi
    
    if ! mkdir -p "$target_dir" 2>/dev/null; then
        if [ "$target_dir" == "$SYSTEM_INSTALL_DIR" ]; then
             MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_SYS_DIR_RO"
             target_dir="$USER_INSTALL_DIR"; link_path="$USER_BIN"
             mkdir -p "$target_dir" || { MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_INSTALL_FAIL"; exit 1; }
        else
             MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_NO_PERM $target_dir"; exit 1;
        fi
    fi

    echo -e "${CYAN}$M_INSTALL_PATH $target_dir${NC}"
    mkdir -p "$target_dir" "${target_dir}/steamcmd_common" "${target_dir}/js-mods" "${target_dir}/backups"
    
    if [ -f "$0" ] && [[ "$0" != *"bash"* ]] && [[ "$0" != *"/fd/"* ]]; then
        cp "$0" "$target_dir/l4m"
    else
        # 使用新下载器自我下载
        download_file "soloxiaoye2022/server_install/main/server_install/linux/init.sh" "$target_dir/l4m" "L4M Script" || { MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_DL_FAIL"; exit 1; }
    fi
    chmod +x "$target_dir/l4m"
    
    mkdir -p "$(dirname "$link_path")"
    if ln -sf "$target_dir/l4m" "$link_path" 2>/dev/null; then
        echo -e "$M_LINK_CREATED $link_path"
    else
        MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_LINK_FAIL l4m='$target_dir/l4m'"
    fi
    
    # 修复：正确迁移旧配置，避免覆盖为空
    if [ "$MANAGER_ROOT" != "$target_dir" ]; then
         if [ -s "${MANAGER_ROOT}/servers.dat" ]; then cp -f "${MANAGER_ROOT}/servers.dat" "$target_dir/"; fi
         if [ -s "${MANAGER_ROOT}/config.dat" ]; then cp -f "${MANAGER_ROOT}/config.dat" "$target_dir/"; fi
         if [ -s "${MANAGER_ROOT}/plugin_config.dat" ]; then cp -f "${MANAGER_ROOT}/plugin_config.dat" "$target_dir/"; fi
    fi
    touch "$target_dir/servers.dat"
    
    if [[ "$link_path" == "$USER_BIN" ]] && [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_ADD_PATH"
    fi

    # 生成独立更新器
    local updater_path="$target_dir/updater.sh"
    generate_updater "$updater_path"
    
    # 创建 update 别名链接
    local link_dir=$(dirname "$link_path")
    ln -sf "$updater_path" "$link_dir/l4m-update"

    MENU_TITLE="$M_INIT_INSTALL" tui_msgbox "$M_INSTALL_DONE"
    exec "$target_dir/l4m"
}

self_update() {
    echo -e "$M_CHECK_UPDATE"
    local temp="/tmp/l4m_upd.sh"
    rm -f "$temp"
    
    # Force use of a known working mirror for script updates if possible, or use standard download
    # Since we are updating the script itself, we want high reliability.
    
    if download_file "soloxiaoye2022/server_install/main/server_install/linux/init.sh" "$temp" "Update Script"; then
        # 增加文件大小校验 (>10KB) 防止下载到错误页面
        local fsize=$(wc -c < "$temp" 2>/dev/null || echo 0)
        if grep -q "main()" "$temp" && [ "$fsize" -gt 10240 ]; then
            local remote_ver="unknown"
            if grep -q 'L4M_VERSION=' "$temp"; then
                remote_ver=$(grep 'L4M_VERSION=' "$temp" | head -n1 | cut -d'=' -f2 | tr -d '"')
            fi
            echo "$remote_ver" > "$REMOTE_VERSION_CACHE"
            mv "$temp" "$FINAL_ROOT/l4m"; chmod +x "$FINAL_ROOT/l4m"
            MENU_TITLE="$M_UPDATE" tui_msgbox "$M_UPDATE_SUCCESS"; exec "$FINAL_ROOT/l4m"
        else
            MENU_TITLE="$M_UPDATE" tui_msgbox "$M_VERIFY_FAIL\n\n${YELLOW}Debug Info:${NC}\nFile size: $fsize bytes\nContent head:\n$(head -n 5 "$temp")"
            rm "$temp"
        fi
    else
        MENU_TITLE="$M_UPDATE" tui_msgbox "$M_CONN_FAIL"
    fi
}

refresh_remote_version_cache_quiet() {
    local tmp="/tmp/l4m_ver.sh"
    rm -f "$tmp"
    local url="https://raw.githubusercontent.com/soloxiaoye2022/server_install/main/server_install/linux/init.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 15 "$url" -o "$tmp" || return
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O "$tmp" "$url" || return
    else
        return
    fi
    local fsize
    fsize=$(wc -c < "$tmp" 2>/dev/null || echo 0)
    if grep -q 'L4M_VERSION=' "$tmp" && [ "$fsize" -gt 10240 ]; then
        local remote_ver
        remote_ver=$(grep 'L4M_VERSION=' "$tmp" | head -n1 | cut -d'=' -f2 | tr -d '"')
        echo "$remote_ver" > "$REMOTE_VERSION_CACHE"
    fi
    rm -f "$tmp"
}

ensure_remote_version_cached() {
    local need_refresh=0
    if [ ! -f "$REMOTE_VERSION_CACHE" ]; then
        need_refresh=1
    else
        if command -v stat >/dev/null 2>&1 && command -v date >/dev/null 2>&1; then
            local mtime
            local now
            mtime=$(stat -c %Y "$REMOTE_VERSION_CACHE" 2>/dev/null || echo 0)
            now=$(date +%s 2>/dev/null || echo 0)
            if [ "$mtime" -eq 0 ] || [ "$now" -eq 0 ]; then
                need_refresh=1
            elif [ $((now - mtime)) -gt 43200 ]; then
                need_refresh=1
            fi
        fi
    fi
    if [ "$need_refresh" -eq 1 ]; then
        refresh_remote_version_cache_quiet
    fi
}

install_steamcmd() {
    # 修复 SteamCMD Locale (Debian/Ubuntu Root)
    if [ ! -f "${STEAMCMD_DIR}/steamcmd.sh" ]; then
        echo -e "$M_INIT_STEAMCMD"; mkdir -p "${STEAMCMD_DIR}"
        local tmp="/tmp/steamcmd.tar.gz"
        local dl_success=false

        # 让玩家选择下载源
        echo -e "$M_CHOOSE_STEAMCMD_SRC"
        echo -e "  1) $M_STEAMCMD_OFFICIAL"
        echo -e "  2) $M_STEAMCMD_FAST"
        local dl_choice
        read -t 5 -p "$M_SELECT_1_2 $M_SELECT_TIMEOUT: " dl_choice
        [ -z "$dl_choice" ] && dl_choice="2"   # 超时自动选择快速下载


        if [ "$dl_choice" == "2" ]; then
            # 快速下载：复用已有测速 + 镜像列表
            echo -e "$M_DL_STEAMCMD_FAST"
            select_best_mirror

            local fast_url="https://github.com/apples1949/SteamCmdLinuxFile/releases/download/steamcmd-latest/package.tar.gz"
            local try_list=("$BEST_MIRROR")
            for m in "${MIRRORS[@]}"; do
                if [ "$m" != "$BEST_MIRROR" ]; then try_list+=("$m"); fi
            done

            for mirror in "${try_list[@]}"; do
                local current_url=""
                if [ "$mirror" == "DIRECT" ]; then
                    current_url="$fast_url"
                else
                    current_url="${mirror}/${fast_url}"
                fi
                echo -e "$M_STEAMCMD_MIRROR_TRY $current_url"
                if wget -O "$tmp" "$current_url" --timeout=15 -q --show-progress 2>&1; then
                    dl_success=true
                    break
                fi
            done

            if ! $dl_success; then
                echo -e "$M_STEAMCMD_MIRROR_FAIL"
                echo -e "$M_DL_STEAMCMD"
                if wget -O "$tmp" "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"; then
                    dl_success=true
                fi
            fi
        else
            echo -e "$M_DL_STEAMCMD"
            if wget -O "$tmp" "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"; then
                dl_success=true
            fi
        fi

        if $dl_success; then
            echo -e "$M_EXTRACTING"
            tar zxf "$tmp" -C "${STEAMCMD_DIR}"
            rm -f "$tmp"
        else
            echo -e "$M_DL_FAIL"; return 1
        fi
    fi

}

deploy_wizard() {
    MENU_TITLE="$M_DEPLOY"
    local name=""; while [ -z "$name" ]; do
        if ! tui_input "$M_SRV_NAME" "l4d2_srv_1" "name"; then return; fi
        if grep -q "^${name}|" "$DATA_FILE"; then MENU_TITLE="$M_DEPLOY" tui_msgbox "$M_NAME_EXIST"; name=""; fi
    done
    
    local def_path="$HOME/L4D2_Servers/${name}"
    
    local path=""; while [ -z "$path" ]; do
        if ! tui_input "$M_INSTALL_DIR" "$def_path" "path"; then return; fi
        path="${path/#\~/$HOME}"
        if [ -d "$path" ] && [ "$(ls -A "$path")" ]; then MENU_TITLE="$M_DEPLOY" tui_msgbox "$M_DIR_NOT_EMPTY"; path=""; fi
    done
    
    MENU_TITLE="$M_DEPLOY" \
    tui_menu "$M_LOGIN_ANON\n$M_LOGIN_ACC\n\n请选择 Steam 登录方式:" \
        "1. 匿名登录 (Anonymous) - 推荐" \
        "2. 账号登录 (Steam Account)"
        
    local mode
    case $? in
        0) mode="1" ;;
        1) mode="2" ;;
        *) mode="1" ;;
    esac
    
    # 1. Update Cache
    install_steamcmd
    mkdir -p "$SERVER_CACHE_DIR"
    echo -e "$M_UPDATE_CACHE"
    
    # Force UTF-8 for SteamCMD
    export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
    
    local cache_script="${SERVER_CACHE_DIR}/update_cache.txt"
    if [ "$mode" == "2" ]; then
        local u p; 
        if ! tui_input "$M_ACC" "" "u"; then return; fi
        if ! tui_input "$M_PASS" "" "p" "true"; then return; fi
        echo "force_install_dir \"$SERVER_CACHE_DIR\"" > "$cache_script"
        echo "login $u $p" >> "$cache_script"
        echo "@sSteamCmdForcePlatformType linux" >> "$cache_script"
        echo "app_update $DEFAULT_APPID validate" >> "$cache_script"
        echo "quit" >> "$cache_script"
        "${STEAMCMD_DIR}/steamcmd.sh" +runscript "$cache_script" | grep -v "CHTTPClientThreadPool"
    else
        echo "force_install_dir \"$SERVER_CACHE_DIR\"" > "$cache_script"
        echo "login anonymous" >> "$cache_script"
        echo "@sSteamCmdForcePlatformType linux" >> "$cache_script"
        echo "app_info_update 1" >> "$cache_script"
        echo "app_update $DEFAULT_APPID" >> "$cache_script"
        echo "@sSteamCmdForcePlatformType windows" >> "$cache_script"
        echo "app_info_update 1" >> "$cache_script"
        echo "app_update $DEFAULT_APPID" >> "$cache_script"
        echo "@sSteamCmdForcePlatformType linux" >> "$cache_script"
        echo "app_info_update 1" >> "$cache_script"
        echo "app_update $DEFAULT_APPID validate" >> "$cache_script"
        echo "quit" >> "$cache_script"
        "${STEAMCMD_DIR}/steamcmd.sh" +runscript "$cache_script" | grep -v "CHTTPClientThreadPool"
    fi
    
    # 2. Deploy from Cache
    if [ ! -f "${SERVER_CACHE_DIR}/srcds_run" ]; then
        MENU_TITLE="$M_DEPLOY_FAIL" \
        tui_msgbox "${RED}        $M_FAILED $M_DEPLOY_FAIL             ${NC}\n\n$M_NO_SRCDS"
        return
    fi
    
    echo -e "$M_COPY_CACHE"
    mkdir -p "$path"
    
    # 使用新的链接部署逻辑
    deploy_with_links "$SERVER_CACHE_DIR" "$path"
    
    rm -f "$path/update_cache.txt"
    
    # 3. Create local update.txt
    local script="${path}/update.txt"
    sed "s|force_install_dir .*|force_install_dir \"$path\"|" "$cache_script" > "$script"
    
    mkdir -p "${path}/left4dead2/cfg"
    if [ ! -f "${path}/left4dead2/cfg/server.cfg" ]; then
        echo -e "hostname \"$name\"\nrcon_password \"password\"\nsv_lan 0\nsv_cheats 0\nsv_region 4" > "${path}/left4dead2/cfg/server.cfg"
    fi
    
    echo -e "#!/bin/bash\nwhile true; do\n echo 'Starting...'\n ./srcds_run -game left4dead2 -port 27015 +map c2m1_highway +maxplayers 8 -tickrate 60\n echo 'Restarting in 5s...'\n sleep 5\ndone" > "${path}/run_guard.sh"
    chmod +x "${path}/run_guard.sh"
    
    echo "${name}|${path}|STOPPED|27015|false" >> "$DATA_FILE"
    
    MENU_TITLE="$M_SUCCESS" \
    tui_msgbox "${GREEN}        $M_SUCCESS            ${NC}\n\n$M_SRV_READY ${CYAN}${path}${NC}"
}

#=============================================================================
# 6. 插件管理模块 (Plugins)
#=============================================================================

download_packages() {
    tui_header; echo -e "${GREEN}$M_DOWNLOAD_PACKAGES${NC}"
    
    local pkg_dir="${FINAL_ROOT}/downloaded_packages"
    mkdir -p "$pkg_dir"
    
    local choice
    MENU_TITLE="$M_DOWNLOAD_PACKAGES" \
    tui_menu "请选择操作:" \
        "1. 从 GitHub 镜像站下载 (网络)" \
        "2. 从本地仓库导入 (需手动输入路径)" \
        "$M_RETURN"
        
    case $? in
        0) choice="1" ;;
        1) choice="2" ;;
        *) return ;;
    esac
    
    local pkg_array=()
    local source_mode=""
    local source_path=""
    
    if [ "$choice" == "1" ]; then
        source_mode="network"
        echo -e "${CYAN}正在获取插件整合包列表...${NC}"
        
        # 尝试通过 GitHub API 获取文件列表
        select_best_mirror
        local api_url="https://api.github.com/repos/soloxiaoye2022/L4D2-Server-Manager/contents/l4d2_plugins"
        local content=""
        
        # 构建尝试列表
        local try_list=("$BEST_MIRROR")
        for m in "${MIRRORS[@]}"; do if [ "$m" != "$BEST_MIRROR" ]; then try_list+=("$m"); fi; done
        
        for mirror in "${try_list[@]}"; do
             local target_url=""
             if [ "$mirror" == "DIRECT" ]; then
                 target_url="$api_url"
             else
                 target_url="${mirror}/${api_url}"
             fi
             
             echo -e "  正在连接 API: $mirror"
             # 增加 -H Accept: application/vnd.github.v3+json 以明确请求 JSON
             # 增加 -H User-Agent 防止被拦截
             local temp_content
             if temp_content=$(curl -sL --connect-timeout 5 -m 10 -H "Accept: application/vnd.github.v3+json" -H "User-Agent: curl/7.68.0" "$target_url"); then
                 # 增强校验: 必须是 JSON 数组或对象，且包含 "name" 字段
                 # 检查是否以 [ 或 { 开头
                 if [[ "$temp_content" =~ ^\s*\[ || "$temp_content" =~ ^\s*\{ ]]; then
                     if [[ "$temp_content" == *"name"* && "$temp_content" != *"error"* && "$temp_content" != *"404"* ]]; then
                          content="$temp_content"
                          
                          # 立即尝试提取，确保数据有效
                          local test_extract=$(echo "$content" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep -E '\.(7z|zip|tar\.gz|tar\.bz2)$' | grep -i "整合包")
                          if [ -n "$test_extract" ]; then
                              break
                          else
                              echo -e "${YELLOW}  API 返回了 JSON 但未找到整合包，尝试下一个源...${NC}"
                              # echo -e "${GREY}Debug: ${content:0:100}...${NC}"
                          fi
                     else
                          echo -e "${YELLOW}  API 返回内容无效 (不包含 name 或包含 error)，尝试下一个源...${NC}"
                     fi
                 else
                     echo -e "${YELLOW}  API 返回非 JSON 内容 (可能是 HTML)，尝试下一个源...${NC}"
                 fi
             else
                 echo -e "${YELLOW}  连接超时或失败，尝试下一个源...${NC}"
             fi
        done
        
        if [ -z "$content" ]; then
             MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${RED}无法获取插件列表 (所有镜像源均失效)。${NC}"; return
        fi
        
        # 提取文件名 (兼容非 GNU grep)
        local packages=$(echo "$content" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep -E '\.(7z|zip|tar\.gz|tar\.bz2)$' | grep -i "整合包")
             
        if [ -z "$packages" ]; then
            MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${RED}未找到任何整合包。${NC}\n${GREY}API 响应预览:${NC}\n$(echo "$content" | head -n 20)"
            return
        fi
        
        while IFS= read -r pkg; do
           pkg_array+=("$pkg")
        done <<< "$packages"
        
    elif [ "$choice" == "2" ]; then
        source_mode="local"
        local target_path=""
        if ! tui_input "${YELLOW}请输入本地仓库的绝对路径:${NC}" "" "target_path"; then return; fi
        
        if [ ! -d "$target_path" ]; then MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${RED}目录不存在。${NC}"; return; fi
        source_path="$target_path"
        
        echo -e "${CYAN}正在扫描本地仓库...${NC}"
        while IFS= read -r -d '' file; do
            pkg_array+=("$(basename "$file")")
        done < <(find "$target_path" -maxdepth 1 \( -name "*.7z" -o -name "*.zip" -o -name "*.tar.gz" \) -print0)
        
        if [ ${#pkg_array[@]} -eq 0 ]; then MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${RED}未找到压缩包。${NC}"; return; fi
    else
        return
    fi
    
    # 选择逻辑
    if command -v whiptail >/dev/null 2>&1; then
        local args=()
        for ((j=0;j<${#pkg_array[@]};j++)); do
            # 移除颜色代码
            local clean_name=$(strip_colors "${pkg_array[j]}")
            # 使用索引 j 作为 tag，确保唯一且不含空格
            args+=("$j" "${clean_name}" "OFF")
        done
        
        local h=$(tput lines)
        local w=$(tput cols)
        if [ $h -gt 35 ]; then h=35; fi
        if [ $w -gt 160 ]; then w=160; fi
        local list_h=$((h - 8))
        if [ $list_h -lt 5 ]; then list_h=5; fi
        
        local clean_hint=$(strip_colors "$M_SELECT_HINT")
        # Use index as tag to avoid issues with spaces/special chars in names
        choices=$(whiptail --title "$M_SELECT_PACKAGES" --checklist "$clean_hint" $h $w $list_h "${args[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then return; fi
        
        # whiptail returns quoted strings like "item1" "item2"
        # We need to map them back to pkg_array to set sel array
        local sel=(); for ((j=0;j<${#pkg_array[@]};j++)); do sel[j]=0; done
        
        # Removing quotes and matching
        choices="${choices//\"/}"
        
        # 修复: 直接使用 whiptail 返回的索引 (0 1 2...)，避免文件名带空格导致解析错误
        for idx in $choices; do
            sel[$idx]=1
        done
        
        # tot is needed for the processing loop below
        local tot=${#pkg_array[@]}
    else
        # Fallback to pure bash TUI
        local sel=(); for ((j=0;j<${#pkg_array[@]};j++)); do sel[j]=0; done
        local cur=0; local start=0; local size=15; local tot=${#pkg_array[@]}
        
        tput civis; trap 'tput cnorm' EXIT
        
        # 首次绘制头部
        tui_header; echo -e "${GREEN}$M_SELECT_PACKAGES${NC}\n$M_SELECT_HINT\n----------------------------------------"
        
        while true; do
            # ... (Existing pure bash loop logic)
            tui_header; echo -e "${GREEN}$M_SELECT_PACKAGES${NC}\n$M_SELECT_HINT\n----------------------------------------"
            local end=$((start+size)); if [ $end -gt $tot ]; then end=$tot; fi
            for ((j=start;j<end;j++)); do
                local m="[ ]"; if [ "${sel[j]}" -eq 1 ]; then m="[x]"; fi
                # 清除行内余下内容，防止残留
                local clr_eol=$(tput el)
                if [ $j -eq $cur ]; then echo -e "${GREEN}-> $m ${pkg_array[j]}${NC}${clr_eol}"; else echo -e "   $m ${pkg_array[j]}${clr_eol}"; fi
            done
            # 清除列表下方的潜在残留行 (如果列表变短)
            for ((j=end;j<start+size;j++)); do echo "$(tput el)"; done
            
            IFS= read -rsn1 k 2>/dev/null
            if [[ "$k" == "" ]]; then break;
            elif [[ "$k" == " " ]]; then if [ "${sel[cur]}" -eq 0 ]; then sel[cur]=1; else sel[cur]=0; fi
            elif [[ "$k" == $'\x1b' ]]; then
                 read -rsn2 -t 0.1 r
                 if [[ "$r" == "[A" ]]; then ((cur--)); if [ $cur -lt 0 ]; then cur=$((tot-1)); fi; if [ $cur -lt $start ]; then start=$cur; fi
                 elif [[ "$r" == "[B" ]]; then ((cur++)); if [ $cur -ge $tot ]; then cur=0; start=0; fi; if [ $cur -ge $((start+size)) ]; then start=$((cur-size+1)); fi
                 elif [[ -z "$r" ]]; then tput cnorm; return; fi
            elif [[ "$k" == "A" ]]; then ((cur--)); if [ $cur -lt 0 ]; then cur=$((tot-1)); fi; if [ $cur -lt $start ]; then start=$cur; fi
            elif [[ "$k" == "B" ]]; then ((cur++)); if [ $cur -ge $tot ]; then cur=0; start=0; fi; if [ $cur -ge $((start+size)) ]; then start=$((cur-size+1)); fi
            fi
            
            # 修正: start 必须保证 cur 在 [start, start+size) 区间内
            if [ $cur -lt $start ]; then start=$cur; fi
            if [ $cur -ge $((start+size)) ]; then start=$((cur-size+1)); fi
        done
        tput cnorm
    fi
    
    # 处理选中的包
    local c=0
    for ((j=0;j<tot;j++)); do
        if [ "${sel[j]}" -eq 1 ]; then
            local pkg="${pkg_array[j]}"
            # 修正: 解压到单独的目录，避免文件混淆
            local pkg_name_no_ext=$(basename "$pkg" .7z)
            pkg_name_no_ext=$(basename "$pkg_name_no_ext" .zip)
            pkg_name_no_ext=$(basename "$pkg_name_no_ext" .tar.gz)
            
            local extract_root="${pkg_dir}/${pkg_name_no_ext}"
            mkdir -p "$extract_root"
            
            local dest="${extract_root}/${pkg}"
            local process_success=false
            
            if [ "$source_mode" == "network" ]; then
                # 使用新的鲁棒下载器
                if download_file "soloxiaoye2022/L4D2-Server-Manager/main/l4d2_plugins/${pkg}" "$dest" "$pkg"; then
                    process_success=true
                fi
            else
                echo -e "\n${CYAN}正在导入: ${pkg}${NC}"
                if cp "$source_path/$pkg" "$dest"; then process_success=true; else echo -e "${RED}复制失败: ${pkg}${NC}"; fi
            fi
            
            if [ "$process_success" = true ]; then
                echo -e "${GREEN}获取成功，正在解压...${NC}"
                local unzip_success=false
                
                # 解压尝试序列: 7z -> unzip -> tar
                # 注意: 解压到 extract_root
                if command -v 7z >/dev/null 2>&1; then
                    if 7z x -y -o"${extract_root}" "$dest" >/dev/null 2>&1; then unzip_success=true; fi
                fi
                
                if [ "$unzip_success" = false ] && command -v unzip >/dev/null 2>&1; then
                    if file "$dest" | grep -q "Zip archive"; then
                        if unzip -o "$dest" -d "${extract_root}" >/dev/null 2>&1; then unzip_success=true; fi
                    fi
                fi
                
                if [ "$unzip_success" = false ] && command -v tar >/dev/null 2>&1; then
                    if tar -xf "$dest" -C "${extract_root}" >/dev/null 2>&1; then unzip_success=true; fi
                fi
                
                # 失败回显
                if [ "$unzip_success" = false ] && command -v 7z >/dev/null 2>&1; then
                     echo -e "${YELLOW}解压失败，详细错误:${NC}"
                     7z x -y -o"${extract_root}" "$dest"
                fi
                
                if [ "$unzip_success" = true ]; then
                    echo -e "${GREEN}解压完成: ${pkg}${NC}"
                    
                    # 修复: 检查并处理嵌套目录 (例如 Package/Package/JS-MODS -> Package/JS-MODS)
                    # 强制查找 JS-MODS 的位置并拉平
                    local js_mods_path=$(find "${extract_root}" -maxdepth 3 -type d -name "JS-MODS" | head -1)
                    if [ -n "$js_mods_path" ]; then
                        local parent_dir=$(dirname "$js_mods_path")
                        # 如果 JS-MODS 的父目录不是 extract_root，说明有嵌套
                        if [ "$parent_dir" != "$extract_root" ]; then
                            echo -e "${CYAN}检测到深层目录结构，正在自动扁平化...${NC}"
                            
                            # 移动操作: 将 JS-MODS 所在的父目录下的所有内容移动到 extract_root
                            shopt -s dotglob
                            mv "$parent_dir"/* "${extract_root}/" 2>/dev/null
                            shopt -u dotglob
                            
                            # 尝试删除空的父目录结构
                            rmdir "$parent_dir" 2>/dev/null
                            rmdir "$(dirname "$parent_dir")" 2>/dev/null
                        fi
                    else
                        # 如果没找到 JS-MODS，但只有一层目录，也尝试拉平 (通用情况)
                        local num_files=$(find "${extract_root}" -mindepth 1 -maxdepth 1 | wc -l)
                        if [ "$num_files" -eq 1 ]; then
                            local single_dir=$(find "${extract_root}" -mindepth 1 -maxdepth 1 -type d)
                            if [ -n "$single_dir" ]; then
                                echo -e "${CYAN}检测到单层嵌套，尝试拉平...${NC}"
                                shopt -s dotglob
                                mv "$single_dir"/* "${extract_root}/" 2>/dev/null
                                shopt -u dotglob
                                rmdir "$single_dir" 2>/dev/null
                            fi
                        fi
                    fi
                    
                    echo -e "${CYAN}文件已保存至: ${extract_root}${NC}"
                    
                    rm -f "$dest"
                    ((c++))
                else
                    echo -e "${RED}解压失败: ${pkg}${NC}"
                fi
            fi
        fi
    done
    
    echo -e "\n${GREEN}处理完成，共成功 ${c} 个包${NC}"
    
    # 下载完成后，尝试自动设置插件库
    if [ $c -gt 0 ]; then
        auto_select_repo
    else
        MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${GREEN}处理完成，共成功 ${c} 个包${NC}"
    fi
}

# 自动扫描并选择下载的插件库
auto_select_repo() {
    local pkg_dir="${FINAL_ROOT}/downloaded_packages"
    local valid_repos=()
    local valid_names=()
    
    # 扫描包含 JS-MODS 的有效目录
    if [ -d "$pkg_dir" ]; then
        while IFS= read -r -d '' dir; do
            if [ -d "$dir/JS-MODS" ]; then
                valid_repos+=("$dir/JS-MODS")
                valid_names+=("$(basename "$dir")")
            fi
        done < <(find "$pkg_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    fi
    
    local count=${#valid_repos[@]}
    
    if [ $count -eq 0 ]; then
        MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "$M_NO_VALID_PKG"
    elif [ $count -eq 1 ]; then
        JS_MODS_DIR="${valid_repos[0]}"
        echo "$JS_MODS_DIR" > "$PLUGIN_CONFIG"
        MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${GREEN}$M_REPO_AUTO_SET\n${CYAN}$JS_MODS_DIR${NC}"
    else
        # 多个有效包，让用户选择
        local menu_opts=()
        for name in "${valid_names[@]}"; do
            menu_opts+=("$name")
        done
        
        MENU_TITLE="$M_REPO_SELECT_TITLE" \
        tui_menu "$M_REPO_SELECT_MSG" "${menu_opts[@]}"
        
        local sel=$?
        if [ $sel -ne 255 ] && [ $sel -lt $count ]; then
            JS_MODS_DIR="${valid_repos[$sel]}"
            echo "$JS_MODS_DIR" > "$PLUGIN_CONFIG"
            MENU_TITLE="$M_DOWNLOAD_PACKAGES" tui_msgbox "${GREEN}$M_REPO_AUTO_SET\n${CYAN}$JS_MODS_DIR${NC}"
        fi
    fi
}

manage_plugins() {
    local inst_name="$1"
    local base_path="$2"
    local t="$base_path/left4dead2"
    local rec_dir="$base_path/.plugin_records"
    
    # --- 插件库配置检查逻辑 (Refactored) ---
    
    # 1. 尝试从配置文件读取
    local current_repo=""
    if [ -f "$PLUGIN_CONFIG" ]; then
        current_repo=$(cat "$PLUGIN_CONFIG")
    fi
    
    # 2. 验证当前配置是否有效
    local is_valid=false
    if [ -n "$current_repo" ] && [ -d "$current_repo" ]; then
         # 自动修正: 如果指向了父目录，修正为 JS-MODS
         if [ -d "$current_repo/JS-MODS" ]; then
             current_repo="${current_repo}/JS-MODS"
             echo "$current_repo" > "$PLUGIN_CONFIG"
         fi
         
         # 检查目录内是否有内容 (排除 . ..)
         if [ "$(ls -A "$current_repo")" ]; then
             is_valid=true
         fi
    fi
    
    # 3. 如果配置无效，执行自动发现逻辑
    if [ "$is_valid" = false ]; then
        # 扫描 downloaded_packages 目录
        local pkg_dir="${FINAL_ROOT}/downloaded_packages"
        local valid_repos=()
        local valid_names=()
        
        # 扫描逻辑: 查找包含 JS-MODS 的目录
        if [ -d "$pkg_dir" ]; then
            # 使用 while read 循环处理 find 输出，避免文件名空格问题
            while IFS= read -r -d '' js_mods_path; do
                valid_repos+=("$js_mods_path")
                # 提取包名 (JS-MODS 的父目录名)
                valid_names+=("$(basename "$(dirname "$js_mods_path")")")
            done < <(find "$pkg_dir" -type d -name "JS-MODS" -print0)
        fi
        
        local count=${#valid_repos[@]}
        
        if [ $count -eq 0 ]; then
            # Case 0: 无有效包 -> 提示下载
            MENU_TITLE="$M_PLUG_MANAGE" \
            tui_menu "$M_REPO_INVALID_NO_LOCAL" \
                "1. $M_GO_DOWNLOAD" \
                "2. $M_RETURN"
            
            if [ $? -eq 0 ]; then
                download_packages
                return
            else
                return
            fi
            
        elif [ $count -eq 1 ]; then
            # Case 1: 只有一个有效包 -> 自动选择
            current_repo="${valid_repos[0]}"
            echo "$current_repo" > "$PLUGIN_CONFIG"
            MENU_TITLE="$M_PLUG_MANAGE" tui_msgbox "${GREEN}$M_REPO_AUTO_SET\n${CYAN}$current_repo${NC}"
            is_valid=true
            
        else
            # Case >1: 多个有效包 -> 菜单选择
             local menu_opts=()
             for name in "${valid_names[@]}"; do
                 menu_opts+=("$name")
             done
             
             MENU_TITLE="$M_REPO_SELECT_TITLE" \
             tui_menu "$M_REPO_SELECT_MSG" "${menu_opts[@]}"
             
             local sel=$?
             if [ $sel -ne 255 ] && [ $sel -lt $count ]; then
                 current_repo="${valid_repos[$sel]}"
                 echo "$current_repo" > "$PLUGIN_CONFIG"
                 MENU_TITLE="$M_PLUG_MANAGE" tui_msgbox "${GREEN}$M_REPO_AUTO_SET\n${CYAN}$current_repo${NC}"
                 is_valid=true
             else
                 return
             fi
        fi
    fi
    
    # 最终检查
    if [ "$is_valid" = false ]; then
        MENU_TITLE="$M_PLUG_MANAGE" tui_msgbox "$M_REPO_STILL_INVALID"
        return
    fi
    
    # 更新全局变量
    JS_MODS_DIR="$current_repo"
    
    mkdir -p "$rec_dir"
    
    # 1. Gather all available plugins
    local available_plugins=()
    while IFS= read -r -d '' dir; do
        available_plugins+=("$(basename "$dir")")
    done < <(find "$JS_MODS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    
    if [ ${#available_plugins[@]} -eq 0 ]; then MENU_TITLE="$M_PLUG_MANAGE" tui_msgbox "$M_REPO_EMPTY"; return; fi
    
    # 2. Check installed status
    local installed_status=() # 1 for installed, 0 for not
    
    for plug in "${available_plugins[@]}"; do
        if [ -f "$rec_dir/$plug" ]; then
            installed_status+=(1)
        else
            installed_status+=(0)
        fi
    done
    
    local tot=${#available_plugins[@]}
    local choices=""
    local new_selection=()
    
    # 3. Show Checklist
    if command -v whiptail >/dev/null 2>&1; then
        local args=()
        local pre_selected=0
        for ((i=0; i<tot; i++)); do
             # Strip colors for whiptail
             local clean_name=$(echo "${available_plugins[i]}" | sed 's/\\033\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*m//g')
             local status="OFF"
             if [ "${installed_status[i]}" -eq 1 ]; then
                 status="ON"
                 pre_selected=$((pre_selected+1))
             fi
             args+=("$i" "$clean_name" "$status")
        done
        
        local h=$(tput lines)
        local w=$(tput cols)
        if [ $h -gt 35 ]; then h=35; fi
        if [ $w -gt 160 ]; then w=160; fi
        local list_h=$((h - 8))
        if [ $list_h -lt 5 ]; then list_h=5; fi

        local inst_info=""
        if [ -n "$inst_name" ]; then
            inst_info="$M_INSTANCE_NAME_LABEL $inst_name\n$M_INSTANCE_DIR_LABEL $base_path\n"
        fi
        local count_text
        count_text=$(printf "$M_SELECTED_COUNT_LABEL" "$pre_selected" "$tot")
        # 先放操作提示，再放实例信息和数量，让第一行永远是“空格/回车”等说明
        local raw_hint="$M_SELECT_HINT\n${inst_info}${count_text}"
        local clean_hint
        clean_hint=$(printf "%b" "$raw_hint" | sed 's/\\033\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*m//g')
        # Use index as tag to avoid issues with spaces/special chars in names
        choices=$(whiptail --title "$M_PLUG_MANAGE" --checklist "$clean_hint" $h $w $list_h "${args[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then return; fi
        
        # Process choices
        choices="${choices//\"/}"
        
        for ((i=0; i<tot; i++)); do new_selection[i]=0; done
        for idx in $choices; do
            new_selection[$idx]=1
        done
        
    else
        # Fallback to pure bash TUI
        local sel=("${installed_status[@]}")
        local cur=0; local start=0; 
        local size=$(($(tput lines) - 8))
        if [ $size -lt 5 ]; then size=5; fi
        
        tput civis; trap 'tput cnorm' EXIT
        
        while true; do
            tui_header
            local inst_info=""
            if [ -n "$inst_name" ]; then
                inst_info="$M_INSTANCE_NAME_LABEL $inst_name\n$M_INSTANCE_DIR_LABEL $base_path\n"
            fi
            local pre_selected_cli=0
            for ((j=0;j<tot;j++)); do
                if [ "${sel[j]}" -eq 1 ]; then pre_selected_cli=$((pre_selected_cli+1)); fi
            done
            local count_text_cli
            count_text_cli=$(printf "$M_SELECTED_COUNT_LABEL" "$pre_selected_cli" "$tot")
            echo -e "$M_PLUG_MANAGE\n$inst_info$count_text_cli\n$M_SELECT_HINT\n----------------------------------------"
            local end=$((start+size)); if [ $end -gt $tot ]; then end=$tot; fi
            for ((j=start;j<end;j++)); do
                local m="[ ]"; if [ "${sel[j]}" -eq 1 ]; then m="[x]"; fi
                local status_mark=""
                if [ "${installed_status[j]}" -eq 1 ]; then status_mark="*"; fi
                
                local clr_eol=$(tput el)
                if [ $j -eq $cur ]; then echo -e "${GREEN}-> $m ${available_plugins[j]}${status_mark}${NC}${clr_eol}"; else echo -e "   $m ${available_plugins[j]}${status_mark}${clr_eol}"; fi
            done
            for ((j=end;j<start+size;j++)); do echo "$(tput el)"; done
            
            IFS= read -rsn1 k 2>/dev/null
            if [[ "$k" == "" ]]; then break;
            elif [[ "$k" == " " ]]; then if [ "${sel[cur]}" -eq 0 ]; then sel[cur]=1; else sel[cur]=0; fi
            elif [[ "$k" == $'\x1b' ]]; then
                 read -rsn2 -t 0.1 r
                 if [[ "$r" == "[A" ]]; then ((cur--)); if [ $cur -lt 0 ]; then cur=$((tot-1)); fi; if [ $cur -lt $start ]; then start=$cur; fi
                 elif [[ "$r" == "[B" ]]; then ((cur++)); if [ $cur -ge $tot ]; then cur=0; start=0; fi; if [ $cur -ge $((start+size)) ]; then start=$((cur-size+1)); fi
                 elif [[ -z "$r" ]]; then tput cnorm; return; fi
            elif [[ "$k" == "A" ]]; then ((cur--)); if [ $cur -lt 0 ]; then cur=$((tot-1)); fi; if [ $cur -lt $start ]; then start=$cur; fi
            elif [[ "$k" == "B" ]]; then ((cur++)); if [ $cur -ge $tot ]; then cur=0; start=0; fi; if [ $cur -ge $((start+size)) ]; then start=$((cur-size+1)); fi
            fi
            
            if [ $cur -lt $start ]; then start=$cur; fi
            if [ $cur -ge $((start+size)) ]; then start=$((cur-size+1)); fi
        done
        tput cnorm
        
        new_selection=("${sel[@]}")
    fi
    
    # 4. Execute Changes
    local to_install=()
    local to_uninstall=()
    
    for ((i=0; i<tot; i++)); do
        if [ "${installed_status[i]}" -eq 0 ] && [ "${new_selection[i]}" -eq 1 ]; then
            to_install+=("${available_plugins[i]}")
        elif [ "${installed_status[i]}" -eq 1 ] && [ "${new_selection[i]}" -eq 0 ]; then
            to_uninstall+=("${available_plugins[i]}")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ] && [ ${#to_uninstall[@]} -eq 0 ]; then return; fi
    
    echo -e "\n${CYAN}正在应用变更...${NC}"
    
    # Install
    for plug in "${to_install[@]}"; do
        echo -e "${GREEN}[安装] $plug${NC}"
        local plugin_dir="${JS_MODS_DIR}/${plug}"
        # 插件包通常以 left4dead2 作为根目录，这里自动进入该子目录，避免在实例下出现 left4dead2/left4dead2 的嵌套
        local src_root="$plugin_dir"
        if [ -d "$plugin_dir/left4dead2" ]; then
            src_root="$plugin_dir/left4dead2"
        fi
        local rec_file="$rec_dir/${plug}"
        > "$rec_file"
        
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                local rel_path=${file#"$src_root/"}
                local dest="$t/$rel_path"
                mkdir -p "$(dirname "$dest")"
                cp -f "$file" "$dest" 2>/dev/null
                echo "$rel_path" >> "$rec_file"
            fi
        done < <(find "$plugin_dir" -type f -print0 | sort -z)
    done
    
    # Uninstall
    for plug in "${to_uninstall[@]}"; do
        echo -e "${YELLOW}[卸载] $plug${NC}"
        local rec_file="$rec_dir/${plug}"
        if [ -f "$rec_file" ]; then
            local dirs_to_clean=()
            while IFS= read -r file_path; do
                if [ -n "$file_path" ]; then
                    local full_path="$t/$file_path"
                    if [ -f "$full_path" ]; then rm -f "$full_path" 2>/dev/null; fi
                    dirs_to_clean+=("$(dirname "$full_path")")
                fi
            done < "$rec_file"
            
            local sorted_dirs=($(printf "%s\n" "${dirs_to_clean[@]}" | sort -u -r))
            for d_path in "${sorted_dirs[@]}"; do
                if [[ "$d_path" == "$t"* ]] && [ -d "$d_path" ]; then rmdir -p --ignore-fail-on-non-empty "$d_path" 2>/dev/null; fi
            done
            rm -f "$rec_file"
        fi
    done
    
    MENU_TITLE="$M_PLUG_MANAGE" tui_msgbox "$M_DONE"
}



plugins_menu() {
    local n="$1"
    local p="$2"
    # 修复：只检查基础目录，不强制要求 left4dead2 子目录存在 (可能尚未首次运行生成)
    if [ ! -d "$p" ]; then 
        MENU_TITLE="$M_OPT_PLUGINS" tui_msgbox "${RED}目录错: 找不到路径 '$p'${NC}\n\n${YELLOW}可能原因: 实例路径被移动或包含特殊字符。${NC}"
        return
    fi
    
    # 确保 left4dead2 目录存在
    mkdir -p "$p/left4dead2"
    
    while true; do
        tui_menu "$M_OPT_PLUGINS" "$M_PLUG_MANAGE" "$M_PLUG_PLAT" "$M_PLUG_REPO" "$M_RETURN"
        case $? in
            0) manage_plugins "$n" "$p" ;; 
            1) inst_plat "$p" ;; 
            2) set_plugin_repo ;; 
            3|255) return ;;
        esac
    done
}

set_plugin_repo() {
    local pkg_dir="${FINAL_ROOT}/downloaded_packages"
    
    local choice
    MENU_TITLE="$M_PLUG_REPO" \
    tui_menu "$M_CUR_REPO $JS_MODS_DIR\n\n请选择操作:" \
        "1. 选择已下载的插件整合包" \
        "2. 手动输入插件库目录" \
        "3. 返回"
        
    case $? in
        0) choice="1" ;;
        1) choice="2" ;;
        *) return ;;
    esac
    
    # 动态计算分页大小 (这里也要用，因为 case 1 用到了 size)
    local term_lines=$(tput lines)
    local size=$((term_lines - 8))
    if [ $size -lt 5 ]; then size=5; fi
    
    case "$choice" in
        1)
            local pkg_list=()
            # 仅列出包含 JS-MODS 的有效包
            for dir in "$pkg_dir"/*; do 
                if [ -d "$dir" ] && [ -d "$dir/JS-MODS" ]; then 
                    pkg_list+=("$(basename "$dir")"); 
                fi; 
            done
            
            if [ ${#pkg_list[@]} -eq 0 ]; then MENU_TITLE="$M_PLUG_REPO" tui_msgbox "${YELLOW}没有找到有效的插件整合包 (需包含 JS-MODS 目录)${NC}"; return; fi
            
            local cur=0
            local tot=${#pkg_list[@]}
            
            # 使用统一的 TUI 菜单选择
            local menu_opts=()
            for ((j=0;j<tot;j++)); do
                menu_opts+=("${pkg_list[j]}")
            done
            
            MENU_TITLE="$M_PLUG_REPO" \
            tui_menu "$M_SELECT_HINT" "${menu_opts[@]}"
            
            local selection=$?
            if [ $selection -eq 255 ]; then return; fi
            
            cur=$selection
            
            if [ $cur -lt ${#pkg_list[@]} ]; then
                local selected_dir="$pkg_dir/${pkg_list[$cur]}/JS-MODS"
                # 双重检查
                if [ -d "$selected_dir" ]; then
                    JS_MODS_DIR="$selected_dir"; echo "$selected_dir" > "$PLUGIN_CONFIG"
                    MENU_TITLE="$M_PLUG_REPO" tui_msgbox "${GREEN}已选择插件库: $selected_dir${NC}"
                else
                    MENU_TITLE="$M_PLUG_REPO" tui_msgbox "${RED}错误: 目录结构异常${NC}"
                fi
            fi
            ;;
        2)
            local new
            if tui_input "$M_NEW_REPO_PROMPT" "$JS_MODS_DIR" "new"; then
                if [ -n "$new" ]; then
                    JS_MODS_DIR="$new"; echo "$new" > "$PLUGIN_CONFIG"
                    mkdir -p "$new"; MENU_TITLE="$M_PLUG_REPO" tui_msgbox "$M_SAVED"
                fi
            fi
            sleep 1
            ;;
        *) return ;;
    esac
}

inst_plat() {
    local d="$1/left4dead2"; mkdir -p "$d"; cd "$d" || return
    local pkg_dir="$FINAL_ROOT/pkg"
    if [ -f "$pkg_dir/mm.tar.gz" ] && [ -f "$pkg_dir/sm.tar.gz" ]; then
        echo -e "$M_LOCAL_PKG"
        tar -zxf "$pkg_dir/mm.tar.gz" && tar -zxf "$pkg_dir/sm.tar.gz"
    else
        echo -e "$M_CONN_OFFICIAL"
        local m=$(curl -s "https://www.sourcemm.net/downloads.php?branch=stable" | grep -Eo "https://[^']+linux.tar.gz" | head -1)
        local s=$(curl -s "http://www.sourcemod.net/downloads.php?branch=stable" | grep -Eo "https://[^']+linux.tar.gz" | head -1)
        
        if [ -z "$m" ] || [ -z "$s" ]; then MENU_TITLE="$M_PLUG_PLAT" tui_msgbox "$M_GET_LINK_FAIL"; return; fi
        
        echo -e "MetaMod: ${GREY}$(basename "$m")${NC}"
        echo -e "SourceMod: ${GREY}$(basename "$s")${NC}"
        
        if ! wget -O mm.tar.gz "$m" || ! wget -O sm.tar.gz "$s"; then
             MENU_TITLE="$M_PLUG_PLAT" tui_msgbox "$M_DL_FAIL"; rm -f mm.tar.gz sm.tar.gz; return
        fi
        
        tar -zxf mm.tar.gz && tar -zxf sm.tar.gz
        rm mm.tar.gz sm.tar.gz
    fi
    if [ -f "$d/addons/metamod.vdf" ]; then sed -i '/"file"/c\\t"file"\t"..\/left4dead2\/addons\/metamod\/bin\/server"' "$d/addons/metamod.vdf"; fi
    MENU_TITLE="$M_PLUG_PLAT" tui_msgbox "${GREEN}$M_SUCCESS $M_DONE${NC}"
}

#=============================================================================
# 7. 管理与辅助
#=============================================================================

load_i18n() {
    local raw="$1"
    local lang="${raw//[[:space:]]/}"
    
    # 宽松匹配：只要包含 zh 就认为是中文
    if [[ "$lang" == *"zh"* ]]; then
        M_TITLE="=== L4D2 管理器 (L4M) ==="
        M_WELCOME="欢迎使用 L4D2 Server Manager (L4M)"
        M_TEMP_RUN="检测到您当前通过临时方式运行 (管道/临时目录)。"
        M_REC_INSTALL="为了获得最佳体验，建议将管理器安装到系统："
        M_F_PERSIST="  • ${GREEN}数据持久化${NC}: 服务器配置和数据将安全保存，防误删。"
        M_F_ACCESS="  • ${GREEN}便捷访问${NC}: 安装后只需输入 ${CYAN}l4m${NC} 即可随时管理。"
        M_F_ADV="  • ${GREEN}高级功能${NC}: 支持开机自启、流量监控等特性。"
        M_ASK_INSTALL="是否立即安装到系统? (Y/n): "
        M_TEMP_MODE="${GREY}进入临时运行模式...${NC}"
        M_MAIN_MENU="L4M 主菜单"
        M_DEPLOY="部署新实例"
        M_MANAGE="实例管理"
        M_UPDATE="系统更新"
        M_DEPS="依赖管理 / 换源"
        M_LANG="切换语言 / Language"
        M_UNINSTALL_MENU="卸载 / 重置系统"
        M_EXIT="退出"
        M_SUCCESS="${GREEN}[成功]${NC}"
        M_FAILED="${RED}[失败]${NC}"
        M_INIT_INSTALL="正在初始化安装向导..."
        M_SYS_DIR_RO="${RED}系统目录不可写，回退到用户目录...${NC}"
        M_INSTALL_FAIL="${RED}安装失败。${NC}"
        M_NO_PERM="${RED}无权限创建${NC}"
        M_INSTALL_PATH="安装路径:"
        M_DL_SCRIPT="${YELLOW}下载最新脚本...${NC}"
        M_DL_FAIL="${RED}下载失败${NC}"
        M_LINK_CREATED="${GREEN}链接已创建:${NC}"
        M_LINK_FAIL="${YELLOW}无法创建链接，请手动添加 alias${NC}"
        M_ADD_PATH="${YELLOW}请将 $HOME/bin 加入 PATH 环境变量。${NC}"
        M_INSTALL_DONE="${GREEN}安装完成！输入 l4m 启动。${NC}"
        M_CHECK_UPDATE="${CYAN}检查更新...${NC}"
        M_UPDATE_SUCCESS="${GREEN}更新成功！${NC}"
        M_VERIFY_FAIL="${RED}校验失败${NC}"
        M_CONN_FAIL="${RED}连接失败${NC}"
        M_MISSING_DEPS="${YELLOW}检测到缺失依赖:${NC}"
        M_TRY_SUDO="${CYAN}尝试使用 sudo 安装 (可能需输密码)...${NC}"
        M_INSTALL_OK="${GREEN}安装成功${NC}"
        M_MANUAL_INSTALL="${RED}无法自动安装。请手动执行:${NC}"
        M_NEED_ROOT="${RED}需Root权限${NC}"
        M_TRAFFIC_STATS="${CYAN}流量统计:${NC}"
        M_REALTIME="实时:"
        M_TODAY="今日:"
        M_MONTH="本月:"
        M_NO_HISTORY="暂无历史数据"
        M_TRAFFIC_UNSUPPORTED="${YELLOW}当前系统未检测到兼容的流量统计后端，无法按端口统计流量。${NC}"
        M_PRESS_KEY="${YELLOW}按任意键返回...${NC}"
        M_INIT_STEAMCMD="${YELLOW}初始化 SteamCMD...${NC}"
        M_DL_STEAMCMD="${CYAN}正在下载 SteamCMD 安装包...${NC}"
        M_EXTRACTING="${CYAN}解压中...${NC}"
        M_SELECT_TIMEOUT="(5秒无操作自动选择快速下载)"
        M_CHOOSE_STEAMCMD_SRC="${CYAN}请选择 SteamCMD 下载源:${NC}"
        M_STEAMCMD_OFFICIAL="Steam 官方源 (steamcdn-a.akamaihd.net)"
        M_STEAMCMD_FAST="快速下载 (GitHub 镜像加速)"
        M_DL_STEAMCMD_FAST="${CYAN}正在通过快速源下载 SteamCMD...${NC}"
        M_STEAMCMD_MIRROR_TRY="${CYAN}尝试镜像:${NC}"
        M_STEAMCMD_MIRROR_FAIL="${YELLOW}所有镜像失败，回退到官方源...${NC}"
        M_CHOOSE_STEAMCMD_SRC="${CYAN}请选择 SteamCMD 下载源:${NC}"
        M_STEAMCMD_OFFICIAL="Steam 官方源 (steamcdn-a.akamaihd.net)"
        M_STEAMCMD_FAST="快速下载 (GitHub 镜像加速)"
        M_DL_STEAMCMD_FAST="${CYAN}正在通过快速源下载 SteamCMD...${NC}"
        M_STEAMCMD_MIRROR_TRY="${CYAN}尝试镜像:${NC}"
        M_STEAMCMD_MIRROR_FAIL="${YELLOW}所有镜像失败，回退到官方源...${NC}"
=
        M_SRV_NAME="服务器名称"
        M_NAME_EXIST="${RED}名称已存在${NC}"
        M_INSTALL_DIR="安装目录"
        M_DIR_NOT_EMPTY="${RED}目录不为空${NC}"
        M_LOGIN_ANON="1. 匿名登录"
        M_LOGIN_ACC="2. 账号登录"
        M_SELECT_1_2="选择 (1/2)"
        M_START_DL="${CYAN}开始下载...${NC}"
        M_ACC="账号"
        M_PASS="密码"
        M_NO_SRCDS="未找到 srcds_run，请检查上方 SteamCMD 报错。"
        M_SRV_READY="服务器已就绪:"
        M_ST_RUN="${GREEN}[运行]${NC}"
        M_ST_STOP="${RED}[停止]${NC}"
        M_ST_AUTO="${CYAN}[自启]${NC}"
        M_NO_INSTANCE="${YELLOW}无实例${NC}"
        M_RETURN="返回"
        M_SELECT_INSTANCE="选择实例:"
        M_OPT_START="启动"
        M_OPT_STOP="停止"
        M_OPT_RESTART="重启"
        M_OPT_UPDATE="更新核心服务端 (所有实例)"
        M_OPT_CONSOLE="控制台"
        M_OPT_LOGS="日志"
        M_OPT_TRAFFIC="流量统计"
        M_OPT_ARGS="配置启动参数"
        M_OPT_PLUGINS="插件管理"
        M_OPT_BACKUP="备份服务端"
        M_OPT_DELETE="删除实例"
        M_OPT_AUTO_ON="开启自启"
        M_OPT_AUTO_OFF="关闭自启"
        M_STOP_BEFORE_UPDATE="${YELLOW}警告: 此操作将更新核心文件，所有链接实例都会受影响。${NC}"
        M_ASK_STOP_UPDATE="建议在所有服务器空闲时进行。\n是否继续更新主服务端? (y/n): "
        M_ASK_DELETE="${RED}警告: 即将删除实例 '%s'${NC}\n路径: ${YELLOW}%s${NC}\n此操作不可逆！\n确认删除? (y/N): "
        M_DELETE_OK="${GREEN}实例 '%s' 已删除。${NC}"
        M_DELETE_CANCEL="${YELLOW}取消删除。${NC}"
        M_NO_UPDATE_SCRIPT="${RED}未找到 update.txt${NC}"
        M_ASK_REBUILD="${YELLOW}是否以匿名模式重建更新脚本? (y/n)${NC}"
        M_CALL_STEAMCMD="${CYAN}正在调用 SteamCMD 更新...${NC}"
        M_UPDATED="更新完成"
        M_DEPLOY_FAIL="部署失败"
        M_PORT_OCCUPIED="${RED}端口被占用!${NC}"
        M_START_SENT="${GREEN}启动指令已发送${NC}"
        M_STOPPED="${GREEN}已停止${NC}"
        M_NOT_RUNNING="${RED}未运行${NC}"
        M_DETACH_HINT="${YELLOW}按 Ctrl+B, D 离线${NC}"
        M_NO_LOG="${RED}无日志(请确认已加-condebug)${NC}"
        M_CURRENT="${CYAN}当前:${NC}"
        M_NEW_CMD="${YELLOW}新指令:${NC}"
        M_SAVED="${GREEN}保存${NC}"
        M_ARGS_MENU_HINT="请选择要编辑/启用的启动项:\n(当前启动项后面会标注 [当前])"
        M_ARGS_ADD="添加新启动项"
        M_ARGS_ACTIVE="[当前]"
        M_ARGS_NAME_PROMPT="启动项名称:"
        M_ARGS_EDIT="编辑当前实例启动参数"
        M_ARGS_RESTORE_DEFAULT="恢复默认启动参数"
        M_ARGS_SAVE_AS_INSTANCE_DEFAULT="保存当前启动项为当前实例默认启动项"
        M_ARGS_SAVE_AS_SCHEME="保存当前实例启动项为启动项方案"
        M_ARGS_CHOOSE_SCHEME="启动项方案选择"
        M_NO_SCHEMES="暂无可用方案"
        M_AUTO_SET="${GREEN}自启已设置为:${NC}"
        M_BACKUP_START="${CYAN}正在执行精简备份 (含Metamod、插件清单及数据)...${NC}"
        M_BACKUP_OK="${GREEN}备份成功:${NC}"
        M_BACKUP_FAIL="${RED}备份失败${NC}"
        M_DIR_ERR="${RED}目录错${NC}"
        M_PLUG_MANAGE="管理插件 (安装/卸载)"
        M_PLUG_PLAT="安装平台(SM/MM)"
        M_PLUG_REPO="设置插件库目录"
        M_INSTALLED_PLUGINS="已安装插件"
        M_DOWNLOAD_PACKAGES="下载插件整合包"
        M_SELECT_PACKAGES="选择插件整合包"
        M_CUR_REPO="${CYAN}当前插件库:${NC}"
        M_NEW_REPO_PROMPT="${YELLOW}请输入新路径 (留空取消):${NC}"
        M_REPO_NOT_FOUND="${RED}插件库不存在:${NC}"
        M_REPO_EMPTY="插件库为空"
        M_INSTALLED="${GREY}[已装]${NC}"
        M_INSTANCE_NAME_LABEL="${CYAN}当前实例:${NC}"
        M_INSTANCE_DIR_LABEL="${CYAN}实例目录:${NC}"
        M_SELECTED_COUNT_LABEL="${YELLOW}当前选中插件: %d / %d 个${NC}"
        M_SELECT_HINT="${YELLOW}操作：空格=选择/取消  回车=确认  方向键=移动  鼠标滚轮=滚动列表${NC}"
        M_DONE="${GREEN}完成${NC}"
        M_LOCAL_PKG="${CYAN}发现本地预置包，正在安装...${NC}"
        M_CONN_OFFICIAL="${CYAN}正在连接官网(sourcemod.net)获取最新版本...${NC}"
        M_GET_LINK_FAIL="${RED}[FAILED] 无法获取下载链接，请检查网络或手动下载。${NC}"
        M_FOUND_EXISTING="检测到系统已安装 L4M，正在启动..."
        M_UPDATE_CACHE="${CYAN}正在更新服务端缓存 (首次可能较慢)...${NC}"
        M_COPY_CACHE="${CYAN}正在从缓存部署实例 (本地复制)...${NC}"
        M_UN_CONF_ONLY="1. 仅重置系统配置 (保留服务器数据)"
        M_UN_INST_ONLY="2. 仅删除所有服务器实例 (保留系统配置)"
        M_UN_FULL="3. 完全卸载 (删除所有数据和程序)"
        M_UN_CONFIRM="${RED}确定要执行此操作吗？此操作不可逆！${NC}"
        M_UN_DONE="${GREEN}操作已完成。${NC}"
        M_UN_FULL_DONE="${GREEN}L4M 已完全卸载。再见！${NC}"
        M_NO_REPO_ASK_DL="未设置插件库或库内无有效插件包 (需包含 JS-MODS 目录)。\n是否立即下载插件整合包?"
        M_REPO_AUTO_SET="已自动选择并设置插件库: "
        M_REPO_SELECT_TITLE="检测到多个有效插件包"
        M_REPO_SELECT_MSG="请选择一个作为当前使用的插件库:"
        M_NO_VALID_PKG="${RED}未找到包含 JS-MODS 结构的有效插件包。${NC}"
        M_REPO_INVALID_HAS_LOCAL="当前插件库无效，但检测到本地已下载了包含 JS-MODS 的整合包。\n是否前往选择？"
        M_REPO_INVALID_NO_LOCAL="当前插件库无效，且本地未找到符合结构 (JS-MODS) 的整合包。\n是否前往下载？"
        M_GO_SELECT_REPO="前往选择插件库"
        M_GO_DOWNLOAD="前往下载插件包"
        M_REPO_STILL_INVALID="插件库仍未正确设置，无法管理插件。"
        M_VER_LOCAL="${CYAN}当前版本:${NC}"
        M_VER_REMOTE="${CYAN}远程最新:${NC}"
        M_VER_REMOTE_UP_TO_DATE="${GREEN}(已是最新)${NC}"
        M_VER_REMOTE_NEED_UPDATE="${YELLOW}(有新版本，建议执行“系统更新”)${NC}"
        M_VER_REMOTE_UNKNOWN="${GREY}远程版本未知 (请先执行一次“系统更新”)${NC}"
        M_VER_TAG_UP_TO_DATE="[最新]"
        M_VER_TAG_NEED_UPDATE="[有更新]"
        M_VER_TAG_UNKNOWN="[远程未知]"
    else
        M_TITLE="=== L4D2 Manager (L4M) ==="
        M_WELCOME="Welcome to L4D2 Server Manager (L4M)"
        M_TEMP_RUN="Running in temporary mode (pipe/temp dir)."
        M_REC_INSTALL="Recommended to install to system:"
        M_F_PERSIST="  • ${GREEN}Persistence${NC}: Configs and data are saved safely."
        M_F_ACCESS="  • ${GREEN}Easy Access${NC}: Type ${CYAN}l4m${NC} to manage anytime."
        M_F_ADV="  • ${GREEN}Advanced${NC}: Auto-start, traffic monitor, etc."
        M_ASK_INSTALL="Install to system now? (Y/n): "
        M_TEMP_MODE="${GREY}Entering temporary mode...${NC}"
        M_MAIN_MENU="Main Menu"
        M_DEPLOY="Deploy New Instance"
        M_MANAGE="Manage Instances"
        M_UPDATE="Update System"
        M_DEPS="Dependencies / Mirrors"
        M_LANG="Language"
        M_UNINSTALL_MENU="Uninstall / Reset"
        M_EXIT="Exit"
        M_SUCCESS="${GREEN}[Success]${NC}"
        M_FAILED="${RED}[Failed]${NC}"
        M_INIT_INSTALL="Initializing installation wizard..."
        M_SYS_DIR_RO="${RED}System dir read-only, falling back to user dir...${NC}"
        M_INSTALL_FAIL="${RED}Installation failed.${NC}"
        M_NO_PERM="${RED}No permission${NC}"
        M_INSTALL_PATH="Install Path:"
        M_DL_SCRIPT="${YELLOW}Downloading latest script...${NC}"
        M_DL_FAIL="${RED}Download failed${NC}"
        M_LINK_CREATED="${GREEN}Link created:${NC}"
        M_LINK_FAIL="${YELLOW}Cannot create link, please add alias manually${NC}"
        M_ADD_PATH="${YELLOW}Please add $HOME/bin to PATH.${NC}"
        M_INSTALL_DONE="${GREEN}Installation done! Type l4m to start.${NC}"
        M_CHECK_UPDATE="${CYAN}Checking for updates...${NC}"
        M_UPDATE_SUCCESS="${GREEN}Update successful!${NC}"
        M_VERIFY_FAIL="${RED}Verification failed${NC}"
        M_CONN_FAIL="${RED}Connection failed${NC}"
        M_MISSING_DEPS="${YELLOW}Missing dependencies:${NC}"
        M_TRY_SUDO="${CYAN}Trying sudo (password may be required)...${NC}"
        M_INSTALL_OK="${GREEN}Installed successfully${NC}"
        M_MANUAL_INSTALL="${RED}Cannot auto-install. Please run:${NC}"
        M_NEED_ROOT="${RED}Root required${NC}"
        M_TRAFFIC_STATS="${CYAN}Traffic Stats:${NC}"
        M_REALTIME="Realtime:"
        M_TODAY="Today:"
        M_MONTH="Month:"
        M_NO_HISTORY="No history data"
        M_TRAFFIC_UNSUPPORTED="${YELLOW}Traffic stats backend not available on this system; per-port stats disabled.${NC}"
        M_PRESS_KEY="${YELLOW}Press any key to return...${NC}"
        M_ARGS_MENU_HINT="Select a launch preset to edit/enable:\n(Current preset is marked [Current])"
        M_ARGS_ADD="Add new launch preset"
        M_ARGS_ACTIVE="[Current]"
        M_ARGS_NAME_PROMPT="Preset name:"
        M_ARGS_EDIT="Edit current instance launch args"
        M_ARGS_RESTORE_DEFAULT="Restore default launch args"
        M_ARGS_SAVE_AS_INSTANCE_DEFAULT="Save current as instance default"
        M_ARGS_SAVE_AS_SCHEME="Save current as a scheme"
        M_ARGS_CHOOSE_SCHEME="Choose scheme"
        M_NO_SCHEMES="No schemes available"
        M_INIT_STEAMCMD="${YELLOW}Initializing SteamCMD...${NC}"
        M_DL_STEAMCMD="${CYAN}Downloading SteamCMD...${NC}"
        M_EXTRACTING="${CYAN}Extracting...${NC}"
        M_SELECT_TIMEOUT="(auto-select fast download in 5s)"
        M_CHOOSE_STEAMCMD_SRC="${CYAN}Choose SteamCMD download source:${NC}"
        M_STEAMCMD_OFFICIAL="Steam Official (steamcdn-a.akamaihd.net)"
        M_STEAMCMD_FAST="Fast Download (GitHub Mirror)"
        M_DL_STEAMCMD_FAST="${CYAN}Downloading SteamCMD via fast mirror...${NC}"
        M_STEAMCMD_MIRROR_TRY="${CYAN}Trying mirror:${NC}"
        M_STEAMCMD_MIRROR_FAIL="${YELLOW}All mirrors failed, falling back to official...${NC}"
        M_SRV_NAME="Server Name"
        M_NAME_EXIST="${RED}Name exists${NC}"
        M_INSTALL_DIR="Install Dir"
        M_DIR_NOT_EMPTY="${RED}Dir not empty${NC}"
        M_LOGIN_ANON="1. Anonymous"
        M_LOGIN_ACC="2. Steam Account"
        M_SELECT_1_2="Select (1/2)"
        M_START_DL="${CYAN}Start downloading...${NC}"
        M_ACC="Account"
        M_PASS="Password"
        M_NO_SRCDS="srcds_run not found, check SteamCMD errors."
        M_SRV_READY="Server ready:"
        M_ST_RUN="${GREEN}[RUNNING]${NC}"
        M_ST_STOP="${RED}[STOPPED]${NC}"
        M_ST_AUTO="${CYAN}[AUTO]${NC}"
        M_NO_INSTANCE="${YELLOW}No Instance${NC}"
        M_RETURN="Return"
        M_SELECT_INSTANCE="Select Instance:"
        M_OPT_START="Start"
        M_OPT_STOP="Stop"
        M_OPT_RESTART="Restart"
        M_OPT_UPDATE="Update Core Server (All Instances)"
        M_OPT_CONSOLE="Console"
        M_OPT_LOGS="Logs"
        M_OPT_TRAFFIC="Traffic Stats"
        M_OPT_ARGS="Launch Args"
        M_OPT_PLUGINS="Plugins"
        M_OPT_BACKUP="Backup"
        M_OPT_DELETE="Delete"
        M_OPT_AUTO_ON="Enable Auto-Start"
        M_OPT_AUTO_OFF="Disable Auto-Start"
        M_STOP_BEFORE_UPDATE="${YELLOW}Warning: This updates core files affecting all linked instances.${NC}"
        M_ASK_STOP_UPDATE="Recommended to run when servers are idle.\nProceed to update Main Server? (y/n): "
        M_ASK_DELETE="${RED}Warning: Deleting instance '%s'${NC}\nPath: ${YELLOW}%s${NC}\nIrreversible!\nConfirm? (y/N): "
        M_DELETE_OK="${GREEN}Instance '%s' deleted.${NC}"
        M_DELETE_CANCEL="${YELLOW}Deletion cancelled.${NC}"
        M_NO_UPDATE_SCRIPT="${RED}update.txt not found${NC}"
        M_ASK_REBUILD="${YELLOW}Rebuild update script (Anonymous)? (y/n)${NC}"
        M_CALL_STEAMCMD="${CYAN}Calling SteamCMD...${NC}"
        M_UPDATED="Update Complete"
        M_DEPLOY_FAIL="Deploy Failed"
        M_PORT_OCCUPIED="${RED}Port occupied!${NC}"
        M_START_SENT="${GREEN}Start command sent${NC}"
        M_STOPPED="${GREEN}Stopped${NC}"
        M_NOT_RUNNING="${RED}Not running${NC}"
        M_DETACH_HINT="${YELLOW}Press Ctrl+B, D to detach${NC}"
        M_NO_LOG="${RED}No log (check -condebug)${NC}"
        M_CURRENT="${CYAN}Current:${NC}"
        M_NEW_CMD="${YELLOW}New:${NC}"
        M_SAVED="${GREEN}Saved${NC}"
        M_AUTO_SET="${GREEN}Auto-start set to:${NC}"
        M_BACKUP_START="${CYAN}Backing up (Metamod, Plugins, Data)...${NC}"
        M_BACKUP_OK="${GREEN}Backup success:${NC}"
        M_BACKUP_FAIL="${RED}Backup failed${NC}"
        M_DIR_ERR="${RED}Dir Error${NC}"
        M_PLUG_MANAGE="Manage Plugins"
        M_PLUG_PLAT="Install Platform (SM/MM)"
        M_PLUG_REPO="Set Plugin Repo"
        M_INSTALLED_PLUGINS="Installed Plugins"
        M_DOWNLOAD_PACKAGES="Download Packages"
        M_SELECT_PACKAGES="Select Packages"
        M_CUR_REPO="${CYAN}Current Repo:${NC}"
        M_NEW_REPO_PROMPT="${YELLOW}New Path (Empty to cancel):${NC}"
        M_REPO_NOT_FOUND="${RED}Repo not found:${NC}"
        M_REPO_EMPTY="Repo empty"
        M_INSTALLED="${GREY}[Installed]${NC}"
        M_INSTANCE_NAME_LABEL="${CYAN}Instance:${NC}"
        M_INSTANCE_DIR_LABEL="${CYAN}Instance Path:${NC}"
        M_SELECTED_COUNT_LABEL="${YELLOW}Selected plugins: %d / %d${NC}"
        M_SELECT_HINT="${YELLOW}Controls: Space=Select/Unselect  Enter=Confirm  ↑/↓=Move  MouseWheel=Scroll list${NC}"
        M_DONE="${GREEN}Done${NC}"
        M_LOCAL_PKG="${CYAN}Found local package, installing...${NC}"
        M_CONN_OFFICIAL="${CYAN}Connecting to official site...${NC}"
        M_GET_LINK_FAIL="${RED}[FAILED] Cannot get download link.${NC}"
        M_FOUND_EXISTING="Found existing installation, starting..."
        M_UPDATE_CACHE="${CYAN}Updating cache...${NC}"
        M_COPY_CACHE="${CYAN}Deploying from cache...${NC}"
        M_UN_CONF_ONLY="1. Reset System Config Only (Keep Servers)"
        M_UN_INST_ONLY="2. Delete All Server Instances (Keep Config)"
        M_UN_FULL="3. Full Uninstall (Remove Everything)"
        M_UN_CONFIRM="${RED}Are you sure? This is irreversible!${NC}"
        M_UN_DONE="${GREEN}Operation completed.${NC}"
        M_UN_FULL_DONE="${GREEN}L4M has been uninstalled. Goodbye!${NC}"
        M_NO_REPO_ASK_DL="Plugin repo not set or invalid (must contain JS-MODS).\nDownload plugin packages now?"
        M_REPO_AUTO_SET="Auto-selected plugin repo: "
        M_REPO_SELECT_TITLE="Multiple Valid Packages Found"
        M_REPO_SELECT_MSG="Please select one as current repo:"
        M_NO_VALID_PKG="${RED}No valid package found (must contain JS-MODS).${NC}"
        M_VER_LOCAL="${CYAN}Current Version:${NC}"
        M_VER_REMOTE="${CYAN}Latest Remote:${NC}"
        M_VER_REMOTE_UP_TO_DATE="${GREEN}(up to date)${NC}"
        M_VER_REMOTE_NEED_UPDATE="${YELLOW}(new version available, run \"Update System\")${NC}"
        M_VER_REMOTE_UNKNOWN="${GREY}Remote version unknown (run \"Update System\" once)${NC}"
        M_VER_TAG_UP_TO_DATE="[Up-to-date]"
        M_VER_TAG_NEED_UPDATE="[Update Available]"
        M_VER_TAG_UNKNOWN="[Remote Unknown]"
    fi
}

change_lang() {
    rm -f "$CONFIG_FILE"
    exec "$0"
}

get_status() { if tmux has-session -t "l4d2_$1" 2>/dev/null; then echo "RUNNING"; else echo "STOPPED"; fi; }

manage_menu() {
    local srvs=(); local opts=()
    while IFS='|' read -r n p s port auto; do
        if [ -n "$n" ]; then
            local st=$(get_status "$n"); local c=""; if [ "$st" == "RUNNING" ]; then c="$M_ST_RUN"; else c="$M_ST_STOP"; fi
            local ac=""; if [ "$auto" == "true" ]; then ac="$M_ST_AUTO"; fi
            srvs+=("$n"); opts+=("$n $c $ac")
        fi
    done < "$DATA_FILE"
    
    if [ ${#srvs[@]} -eq 0 ]; then 
        MENU_TITLE="实例管理" tui_msgbox "$M_NO_INSTANCE"; 
        return; 
    fi
    opts+=("$M_RETURN")
    tui_menu "$M_SELECT_INSTANCE" "${opts[@]}"; local c=$?
    if [ $c -eq 255 ]; then return; fi
    if [ $c -lt ${#srvs[@]} ]; then control_panel "${srvs[$c]}"; fi
}

control_panel() {
    local n="$1"
    # 使用 awk 精确匹配第一列 (服务器名称)，避免 grep 前缀匹配问题 (如 test 匹配 test2)
    local line=$(awk -F'|' -v t="$n" '$1 == t {print $0; exit}' "$DATA_FILE")
    
    if [ -z "$line" ]; then
        MENU_TITLE="实例错误" tui_msgbox "${RED}Error: 无法在数据文件中找到实例 '$n'${NC}"
        return
    fi
    
    local p=$(echo "$line" | cut -d'|' -f2)
    local port=$(echo "$line" | cut -d'|' -f4)
    local auto=$(echo "$line" | cut -d'|' -f5)
    
    while true; do
        local st=$(get_status "$n")
        local a_txt="$M_OPT_AUTO_ON"; if [ "$auto" == "true" ]; then a_txt="$M_OPT_AUTO_OFF"; fi
        
        # 优化: 获取实际运行端口
        local real_port="N/A"
        if [ "$st" == "RUNNING" ]; then
             # 尝试通过 netstat 查找 ./srcds_run 的端口 (仅参考)
             # 更准确的是从 run_guard.sh 中读取配置端口，或者检查 UDP 监听
             # 这里简单显示配置端口 vs 实际监听
             if command -v netstat >/dev/null 2>&1; then
                 # 模糊匹配，可能不准确，仅作参考
                 local check_port=$(netstat -ulnp 2>/dev/null | grep "srcds_linux" | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | head -1)
                 if [ -n "$check_port" ]; then real_port="$check_port"; fi
             fi
        fi
        
        # 读取 run_guard.sh 中的配置端口
        local cfg_port=$(grep -oP "(?<=-port )\d+" "$p/run_guard.sh" | head -1)
        if [ -z "$cfg_port" ]; then cfg_port="$port (Default)"; fi

        local info_str="$n [$st]\n端口设置: $cfg_port | 实际运行: $real_port"
        
        # 设置 Box Title 为服务器名称，Text 为状态信息
        MENU_TITLE="管理实例: $n" \
        tui_menu "$info_str" "$M_OPT_START" "$M_OPT_STOP" "$M_OPT_RESTART" "$M_OPT_UPDATE" "$M_OPT_CONSOLE" "$M_OPT_LOGS" "$M_OPT_TRAFFIC" "$M_OPT_ARGS" "$M_OPT_PLUGINS" "链接管理 / Link Manager" "$a_txt" "$M_OPT_BACKUP" "$M_OPT_DELETE" "$M_RETURN"
        case $? in
            0) start_srv "$n" "$p" "$port" ;;
            1) stop_srv "$n" ;;
            2) stop_srv "$n"; sleep 1; start_srv "$n" "$p" "$port" ;;
            3) update_srv "$n" "$p" ;;
            4) attach_con "$n" ;;
            5) view_log "$p" ;;
            6) view_traffic "$n" "$port" ;;
            7) edit_args "$p" ;;
            8) plugins_menu "$n" "$p" ;;
            9) manage_links_menu "$n" "$p" ;;
            10) toggle_auto "$n" "$line"; break ;; 
            11) backup_srv "$n" "$p" ;;
            12) if delete_srv "$n" "$p"; then return; fi ;;
            13|255) return ;;
        esac
    done
    control_panel "$n"
}

# 链接部署逻辑
deploy_with_links() {
    local src="$1"
    local dest="$2"
    
    # 1. 创建基础目录结构
    mkdir -p "$dest/left4dead2"
    
    # 2. 复制必要的二进制文件 (不链接)
    cp -f "$src/srcds_run" "$dest/" 2>/dev/null
    cp -f "$src/srcds_linux" "$dest/" 2>/dev/null
    cp -f "$src/left4dead2/steam.inf" "$dest/left4dead2/" 2>/dev/null # steam.inf 经常变动，建议复制
    
    # 2.1 复制核心目录 (bin, hl2) - 必须物理复制，不能链接
    if [ -d "$src/bin" ]; then cp -r "$src/bin" "$dest/"; fi
    if [ -d "$src/hl2" ]; then cp -r "$src/hl2" "$dest/"; fi
    
    # 3. 链接目录
    for d in "${LINK_DIRS[@]}"; do
        if [ -d "$src/$d" ]; then
            # 确保父目录存在
            mkdir -p "$(dirname "$dest/$d")"
            ln -sf "$src/$d" "$dest/$d"
        fi
    done
    
    # 4. 链接根文件
    for f in "${LINK_FILES_ROOT[@]}"; do
        if [ -f "$src/$f" ]; then
            mkdir -p "$(dirname "$dest/$f")"
            ln -sf "$src/$f" "$dest/$f"
        fi
    done
    
    # 4.1 链接 VPK (pak01_000.vpk - pak01_999.vpk)
    # 使用通配符查找所有 vpk
    find "$src/left4dead2" -maxdepth 1 -name "pak01_*.vpk" -print0 | while IFS= read -r -d '' vpk; do
        local vpk_name=$(basename "$vpk")
        ln -sf "$vpk" "$dest/left4dead2/$vpk_name"
    done
    
    # 5. 链接 scripts 目录下的文件 (不链接目录本身)
    mkdir -p "$dest/left4dead2/scripts"
    if [ -d "$src/left4dead2/scripts" ]; then
        find "$src/left4dead2/scripts" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' file; do
            local fname=$(basename "$file")
            ln -sf "$file" "$dest/left4dead2/scripts/$fname"
        done
    fi
    
    # 6. 链接 cfg 目录下的文件 (不链接目录本身，排除特定文件)
    mkdir -p "$dest/left4dead2/cfg"
    if [ -d "$src/left4dead2/cfg" ]; then
        find "$src/left4dead2/cfg" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' file; do
            local fname=$(basename "$file")
            # 排除服务器特定配置
            if [[ "$fname" != "server.cfg" && "$fname" != "banned_user.cfg" && "$fname" != "banned_ip.cfg" ]]; then
                ln -sf "$file" "$dest/left4dead2/cfg/$fname"
            fi
        done
    fi
    
    # 7. 创建空目录 (addons, logs 等)
    mkdir -p "$dest/left4dead2/addons"
    mkdir -p "$dest/left4dead2/logs"
}

manage_links_menu() {
    local n="$1"
    local p="$2"
    
    while true; do
        local opts=()
        
        # 构建菜单项，显示链接状态
        # 1. Maps
        local st_maps="[COPIED]"
        if [ -L "$p/left4dead2/maps" ]; then st_maps="${GREEN}[LINKED]${NC}"; else st_maps="${YELLOW}[COPIED]${NC}"; fi
        opts+=("Maps Directory $st_maps")
        
        # 2. Materials
        local st_mat="[COPIED]"
        if [ -L "$p/left4dead2/materials" ]; then st_mat="${GREEN}[LINKED]${NC}"; else st_mat="${YELLOW}[COPIED]${NC}"; fi
        opts+=("Materials Directory $st_mat")
        
        # 3. Models
        # Models 默认是不链接的，但如果用户想链接呢？清单里没说要链接 models，
        # 清单说 "models... 不需要链接"。但这里是管理菜单，也许用户想链接？
        # 暂时只提供清单里的主要目录
        
        # 3. Sound? (Resource/Sound) - resource is linked
        local st_res="[COPIED]"
        if [ -L "$p/left4dead2/resource" ]; then st_res="${GREEN}[LINKED]${NC}"; else st_res="${YELLOW}[COPIED]${NC}"; fi
        opts+=("Resource Directory $st_res")
        
        # 4. DLCs
        local st_dlc="[COPIED]"
        if [ -L "$p/left4dead2_dlc1" ] && [ -L "$p/left4dead2_dlc2" ] && [ -L "$p/left4dead2_dlc3" ]; then 
            st_dlc="${GREEN}[LINKED]${NC}"
        else 
            st_dlc="${YELLOW}[COPIED]${NC}"
        fi
        opts+=("DLC Directories (1-3) $st_dlc")
        
        # 5. VPK Files
        # 检查一个代表性的 vpk
        local st_vpk="[COPIED]"
        if [ -L "$p/left4dead2/pak01_dir.vpk" ]; then st_vpk="${GREEN}[LINKED]${NC}"; else st_vpk="${YELLOW}[COPIED]${NC}"; fi
        opts+=("VPK Files (pak01_*.vpk) $st_vpk")
        
        opts+=("$M_RETURN")
        
        MENU_TITLE="链接管理: $n" \
        tui_menu "选择要切换模式的项目 (Linked <-> Copied)\n${GREY}注意: 转换为独立副本会占用更多空间${NC}" "${opts[@]}"
        
        local choice=$?
        if [ $choice -eq 5 ] || [ $choice -eq 255 ]; then return; fi
        
        case $choice in
            0) toggle_link_dir "$p/left4dead2/maps" "$SERVER_CACHE_DIR/left4dead2/maps" ;;
            1) toggle_link_dir "$p/left4dead2/materials" "$SERVER_CACHE_DIR/left4dead2/materials" ;;
            2) toggle_link_dir "$p/left4dead2/resource" "$SERVER_CACHE_DIR/left4dead2/resource" ;;
            3) 
                toggle_link_dir "$p/left4dead2_dlc1" "$SERVER_CACHE_DIR/left4dead2_dlc1" 
                toggle_link_dir "$p/left4dead2_dlc2" "$SERVER_CACHE_DIR/left4dead2_dlc2"
                toggle_link_dir "$p/left4dead2_dlc3" "$SERVER_CACHE_DIR/left4dead2_dlc3"
                ;;
            4) toggle_link_vpks "$p/left4dead2" "$SERVER_CACHE_DIR/left4dead2" ;;
        esac
    done
}

toggle_link_dir() {
    local link_path="$1"
    local source_path="$2"
    local name=$(basename "$link_path")
    
    if [ -L "$link_path" ]; then
        # 当前是链接 -> 转为副本
        # 逻辑：把链接指向的内容复制到临时目录 -> 删除链接 -> 移回/复制回
        
        MENU_TITLE="取消链接: $name" \
        tui_menu "即将把 '$name' 转换为独立副本。\n这将从主服务端缓存复制文件到此实例。" \
            "1. 确认 (Confirm)" "2. 取消 (Cancel)"
        if [ $? -ne 0 ]; then return; fi
        
        echo -e "${YELLOW}正在解除链接并复制文件...${NC}"
        
        # 1. 记录原始链接指向 (为了安全)
        local target=$(readlink -f "$link_path")
        
        # 2. 删除链接
        rm "$link_path"
        
        # 3. 复制源文件到此位置
        # 注意: cp -r 会复制整个目录
        if cp -r "$source_path" "$link_path"; then
            MENU_TITLE="取消链接" tui_msgbox "${GREEN}成功！'$name' 现在是独立副本。${NC}"
        else
            MENU_TITLE="取消链接" tui_msgbox "${RED}复制失败！尝试恢复链接...${NC}"
            ln -sf "$source_path" "$link_path"
        fi
        
    elif [ -d "$link_path" ]; then
        # 当前是目录 -> 转为链接
        MENU_TITLE="创建链接: $name" \
        tui_menu "${RED}警告: 即将删除本地目录 '$name' 并替换为链接。${NC}\n本地文件将丢失(除非您已备份)！" \
            "1. 确认删除并链接 (Delete & Link)" "2. 取消 (Cancel)"
        if [ $? -ne 0 ]; then return; fi
        
        echo -e "${YELLOW}正在删除本地文件并创建链接...${NC}"
        rm -rf "$link_path"
        ln -sf "$source_path" "$link_path"
        MENU_TITLE="创建链接" tui_msgbox "${GREEN}成功！'$name' 现在链接到主服务端。${NC}"
    else
        MENU_TITLE="错误" tui_msgbox "${RED}路径不存在或类型未知: $link_path${NC}"
    fi
}

toggle_link_vpks() {
    local inst_dir="$1"
    local cache_dir="$2"
    
    # 检查状态
    if [ -L "$inst_dir/pak01_dir.vpk" ]; then
        # Unlink
        MENU_TITLE="取消链接: VPKs" \
        tui_menu "即将把 VPK 文件转换为独立副本 (占用约几GB空间)。" \
            "1. 确认 (Confirm)" "2. 取消 (Cancel)"
        if [ $? -ne 0 ]; then return; fi
        
        echo -e "${YELLOW}正在处理 VPK 文件...${NC}"
        
        find "$inst_dir" -maxdepth 1 -name "pak01_*.vpk" -type l -delete
        cp "$cache_dir"/pak01_*.vpk "$inst_dir/"
        
        MENU_TITLE="取消链接" tui_msgbox "${GREEN}VPK 文件已转换为独立副本。${NC}"
    else
        # Link
        MENU_TITLE="创建链接: VPKs" \
        tui_menu "${RED}即将删除本地 VPK 并使用链接 (节省空间)。${NC}" \
            "1. 确认 (Confirm)" "2. 取消 (Cancel)"
        if [ $? -ne 0 ]; then return; fi
        
        echo -e "${YELLOW}正在链接 VPK 文件...${NC}"
        rm -f "$inst_dir"/pak01_*.vpk
        
        find "$cache_dir" -maxdepth 1 -name "pak01_*.vpk" -print0 | while IFS= read -r -d '' vpk; do
            local vpk_name=$(basename "$vpk")
            ln -sf "$vpk" "$inst_dir/$vpk_name"
        done
        
        MENU_TITLE="创建链接" tui_msgbox "${GREEN}VPK 文件已链接。${NC}"
    fi
}

update_srv() {
    local n="$1"; local p="$2"
    
    # 提示更新的是核心服务端
    MENU_TITLE="更新核心服务端" \
    tui_menu "$M_STOP_BEFORE_UPDATE\n$M_ASK_STOP_UPDATE" \
        "1. 是 (Yes)" \
        "2. 否 (No)"
    if [ $? -ne 0 ]; then return; fi

    echo -e "$M_UPDATE_CACHE"
    mkdir -p "$SERVER_CACHE_DIR"
    local cache_script="${SERVER_CACHE_DIR}/update_cache.txt"
    
    if [ ! -f "$cache_script" ]; then
        # 如果缓存脚本不存在，尝试重建
        MENU_TITLE="更新服务端" \
        tui_menu "$M_NO_UPDATE_SCRIPT\n$M_ASK_REBUILD" \
            "1. 是 (Yes)" \
            "2. 否 (No)"
            
        if [ $? -eq 0 ]; then
            echo "force_install_dir \"$SERVER_CACHE_DIR\"" > "$cache_script"
            echo "login anonymous" >> "$cache_script"
            echo "@sSteamCmdForcePlatformType linux" >> "$cache_script"
            echo "app_info_update 1" >> "$cache_script"
            echo "app_update $DEFAULT_APPID" >> "$cache_script"
            echo "@sSteamCmdForcePlatformType windows" >> "$cache_script"
            echo "app_info_update 1" >> "$cache_script"
            echo "app_update $DEFAULT_APPID" >> "$cache_script"
            echo "@sSteamCmdForcePlatformType linux" >> "$cache_script"
            echo "app_info_update 1" >> "$cache_script"
            echo "app_update $DEFAULT_APPID validate" >> "$cache_script"
            echo "quit" >> "$cache_script"
        else
            return
        fi
    fi
    
    echo -e "$M_CALL_STEAMCMD"
    export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
    
    # 仅更新 Cache，不再执行复制到实例的操作
    "${STEAMCMD_DIR}/steamcmd.sh" +runscript "$cache_script" | grep -v "CHTTPClientThreadPool"
    
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}        $M_SUCCESS $M_UPDATED            ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "${YELLOW}注意: 链接模式的实例已自动更新。${NC}"
    read -n 1 -s -r
}

start_srv() {
    local n="$1"; local p="$2"; local port="$3"
    if [ "$(get_status "$n")" == "RUNNING" ]; then return; fi
    
    local real_port=$(grep -oP "(?<=-port )\d+" "$p/run_guard.sh" | head -1)
    if [ -z "$real_port" ]; then real_port=$port; fi
    
    if check_port "$real_port"; then MENU_TITLE="$M_OPT_START" tui_msgbox "$M_PORT_OCCUPIED"; return; fi
    
    cd "$p" || return
    tmux new-session -d -s "l4d2_$n" "./run_guard.sh"
    echo -e "$M_START_SENT"; sleep 1
}

stop_srv() {
    local n="$1"
    tmux send-keys -t "l4d2_$n" C-c; sleep 1
    if tmux has-session -t "l4d2_$n" 2>/dev/null; then tmux kill-session -t "l4d2_$n"; fi
    echo -e "$M_STOPPED"; sleep 1
}

attach_con() {
    local n="$1"
    if [ "$(get_status "$n")" == "STOPPED" ]; then MENU_TITLE="$M_OPT_CONSOLE" tui_msgbox "$M_NOT_RUNNING"; return; fi
    MENU_TITLE="$M_OPT_CONSOLE" tui_msgbox "$M_DETACH_HINT"
    tmux attach-session -t "l4d2_$n"
}

view_log() {
    local f="$1/left4dead2/console.log"
    if [ -f "$f" ]; then tail -f "$f"; else MENU_TITLE="$M_OPT_LOGS" tui_msgbox "$M_NO_LOG"; fi
}

edit_args() {
    local p="$1"
    local s="$p/run_guard.sh"
    if [ ! -f "$s" ]; then
        MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_NO_SRCDS"
        return
    fi
    local preset_file="$p/run_presets.dat"
    local current_line
    current_line=$(grep "./srcds_run" "$s" | head -n1)
    if [ -z "$current_line" ]; then
        MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_NO_SRCDS"
        return
    fi
    if [ ! -f "$preset_file" ] || ! grep -q '|' "$preset_file" 2>/dev/null; then
        printf "%s|%s\n" "默认" "$current_line" > "$preset_file"
    fi
    while true; do
        current_line=$(grep "./srcds_run" "$s" | head -n1)
        local curr_name="自定义"
        if [ -f "$preset_file" ]; then
            while IFS='|' read -r n_cmd_name n_cmd; do
                if [ "$n_cmd" = "$current_line" ]; then curr_name="$n_cmd_name"; break; fi
            done < "$preset_file"
        fi
        local edit_label="${M_ARGS_EDIT}[${curr_name}]"
        MENU_TITLE="$M_OPT_ARGS"
        tui_menu "$M_ARGS_MENU_HINT" \
            "$edit_label" \
            "$M_ARGS_RESTORE_DEFAULT" \
            "$M_ARGS_SAVE_AS_INSTANCE_DEFAULT" \
            "$M_ARGS_SAVE_AS_SCHEME" \
            "$M_ARGS_CHOOSE_SCHEME" \
            "$M_RETURN"
        case $? in
            0)
                local new_cmd=""
                echo -e "$M_CURRENT $current_line"
                echo -e "$M_NEW_CMD"
                echo -n "  "
                if read -e -i "$current_line" new_cmd; then :; fi
                if [ -z "$new_cmd" ]; then new_cmd="$current_line"; fi
                if [ -z "$new_cmd" ]; then continue; fi
                local esc
                esc=$(printf '%s\n' "$new_cmd" | sed 's:[][\/.^$*]:\\&:g')
                sed -i "s|^\./srcds_run.*|$esc|" "$s"
                MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_SAVED"
                ;;
            1)
                local def_cmd=""
                def_cmd=$(grep -m1 "^默认|" "$preset_file" | cut -d'|' -f2-)
                if [ -z "$def_cmd" ]; then def_cmd="$current_line"; fi
                local esc_def
                esc_def=$(printf '%s\n' "$def_cmd" | sed 's:[][\/.^$*]:\\&:g')
                sed -i "s|^\./srcds_run.*|$esc_def|" "$s"
                local edit_cmd=""
                echo -e "$M_CURRENT $def_cmd"
                echo -e "$M_NEW_CMD"
                echo -n "  "
                if read -e -i "$def_cmd" edit_cmd; then :; fi
                if [ -z "$edit_cmd" ]; then edit_cmd="$def_cmd"; fi
                if [ -z "$edit_cmd" ]; then continue; fi
                local esc2
                esc2=$(printf '%s\n' "$edit_cmd" | sed 's:[][\/.^$*]:\\&:g')
                sed -i "s|^\./srcds_run.*|$esc2|" "$s"
                MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_SAVED"
                ;;
            2)
                local cur_cmd="$current_line"
                if grep -q "^默认|" "$preset_file"; then
                    grep -v "^默认|" "$preset_file" > "${preset_file}.tmp"
                    printf "%s|%s\n" "默认" "$cur_cmd" >> "${preset_file}.tmp"
                    mv "${preset_file}.tmp" "$preset_file"
                else
                    printf "%s|%s\n" "默认" "$cur_cmd" >> "$preset_file"
                fi
                MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_SAVED"
                ;;
            3)
                local inst_name=""
                if [ -f "$DATA_FILE" ]; then
                    inst_name=$(awk -F'|' -v path="$p" '$2==path {print $1; exit}' "$DATA_FILE")
                fi
                if [ -z "$inst_name" ]; then inst_name="方案"; fi
                local scheme_name=""
                MENU_TITLE="$M_OPT_ARGS"
                tui_input "$M_ARGS_NAME_PROMPT" "$inst_name" scheme_name
                if [ -z "$scheme_name" ]; then continue; fi
                local schemes="${FINAL_ROOT}/run_schemes.dat"
                touch "$schemes"
                grep -v "^${scheme_name}|" "$schemes" > "${schemes}.tmp"
                printf "%s|%s|%s\n" "$scheme_name" "$current_line" "$inst_name" >> "${schemes}.tmp"
                mv "${schemes}.tmp" "$schemes"
                MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_SAVED"
                ;;
            4)
                local schemes="${FINAL_ROOT}/run_schemes.dat"
                if [ ! -f "$schemes" ] || ! grep -q '|' "$schemes" 2>/dev/null; then
                    MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_NO_SCHEMES"
                    continue
                fi
                local items=()
                local cmd_map=()
                while IFS='|' read -r scn scc scsrc; do
                    if [ -n "$scn" ] && [ -n "$scc" ]; then
                        items+=("${scn} (${scsrc})")
                        cmd_map+=("$scc|$scn")
                    fi
                done < "$schemes"
                if [ "${#items[@]}" -eq 0 ]; then
                    MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_NO_SCHEMES"
                    continue
                fi
                MENU_TITLE="$M_OPT_ARGS"
                tui_menu "选择一个方案应用到当前实例:" "${items[@]}" "$M_RETURN"
                local idx=$?
                if [ $idx -eq 255 ] || [ $idx -ge $(( ${#items[@]} + 1 )) ]; then continue; fi
                if [ $idx -eq ${#items[@]} ]; then continue; fi
                local pair="${cmd_map[$idx]}"
                local sel_cmd="${pair%%|*}"
                local sel_name="${pair##*|}"
                local esc_sel
                esc_sel=$(printf '%s\n' "$sel_cmd" | sed 's:[][\/.^$*]:\\&:g')
                sed -i "s|^\./srcds_run.*|$esc_sel|" "$s"
                if ! grep -q "^${sel_name}|" "$preset_file"; then
                    printf "%s|%s\n" "$sel_name" "$sel_cmd" >> "$preset_file"
                fi
                MENU_TITLE="$M_OPT_ARGS" tui_msgbox "$M_SAVED"
                ;;
            5|255)
                return
                ;;
        esac
    done
}

toggle_auto() {
    local n="$1"; local l="$2"
    local cur=$(echo "$l" | cut -d'|' -f5)
    local new="true"; if [ "$cur" == "true" ]; then new="false"; fi
    local pre=$(echo "$l" | cut -d'|' -f1-4)
    grep -v "^$n|" "$DATA_FILE" > "${DATA_FILE}.tmp"
    echo "${pre}|${new}" >> "${DATA_FILE}.tmp"
    mv "${DATA_FILE}.tmp" "$DATA_FILE"
    setup_global_resume
    echo -e "$M_AUTO_SET $new"; sleep 1
}

setup_global_resume() {
    if [ "$EUID" -eq 0 ]; then
        local s="/etc/systemd/system/l4m-resume.service"
        if [ ! -f "$s" ]; then
            echo -e "[Unit]\nDescription=L4M Resume\nAfter=network.target\n[Service]\nType=oneshot\nExecStart=$FINAL_ROOT/l4m resume\nRemainAfterExit=yes\n[Install]\nWantedBy=multi-user.target" > "$s"
            systemctl daemon-reload; systemctl enable l4m-resume.service >/dev/null 2>&1
        fi
        local m="/etc/systemd/system/l4m-monitor.service"
        if [ ! -f "$m" ]; then
            echo -e "[Unit]\nDescription=L4M Traffic Monitor\nAfter=network.target\n[Service]\nExecStart=$FINAL_ROOT/l4m monitor\nRestart=always\n[Install]\nWantedBy=multi-user.target" > "$m"
            systemctl daemon-reload; systemctl enable --now l4m-monitor.service >/dev/null 2>&1
        fi
    else
        if ! crontab -l 2>/dev/null | grep -q "l4m resume"; then
            (crontab -l 2>/dev/null; echo "@reboot $FINAL_ROOT/l4m resume >> $FINAL_ROOT/resume.log 2>&1") | crontab -
        fi
    fi
}

resume_all() {
    echo "L4M Resume triggered..."
    while IFS='|' read -r n p s port auto; do
        if [ "$auto" == "true" ]; then
            echo "Starting $n..."
            cd "$p" || continue
            tmux new-session -d -s "l4d2_$n" "./run_guard.sh"
        fi
    done < "$DATA_FILE"
}

backup_srv() {
    local n="$1"; local p="$2"
    mkdir -p "$BACKUP_DIR"
    local f="bk_${n}_$(date +%Y%m%d_%H%M).tar.gz"
    echo -e "$M_BACKUP_START"
    cd "$p" || return
    local list="installed_plugins.txt"
    echo "Backup Time: $(date)" > "$list"
    echo "Server: $n" >> "$list"
    echo "--- Addons ---" >> "$list"
    if [ -d "left4dead2/addons" ]; then ls -1 "left4dead2/addons" >> "$list"; fi
    local rec_dir=".plugin_records"
    if [ -d "$rec_dir" ]; then
        echo "--- $M_INSTALLED_PLUGINS ---" >> "$list"
        for rec_file in "$rec_dir"/*; do if [ -f "$rec_file" ]; then echo "$(basename "$rec_file")" >> "$list"; fi; done
    fi
    local targets=("run_guard.sh" "left4dead2/addons" "left4dead2/cfg" "left4dead2/host.txt" "left4dead2/motd.txt" "left4dead2/mapcycle.txt" "left4dead2/maplist.txt" "$rec_dir" "$list")
    local final=()
    for t in "${targets[@]}"; do if [ -e "$t" ]; then final+=("$t"); fi; done
    tar -czf "${BACKUP_DIR}/$f" --exclude="left4dead2/addons/sourcemod/logs" --exclude="*.log" "${final[@]}"
    rm -f "$list"
    
    if [ $? -eq 0 ]; then 
        MENU_TITLE="$M_OPT_BACKUP" tui_msgbox "$M_BACKUP_OK backups/$f ($(du -h "${BACKUP_DIR}/$f" | cut -f1))"
    else 
        MENU_TITLE="$M_OPT_BACKUP" tui_msgbox "$M_BACKUP_FAIL"
    fi
}

delete_srv() {
    local n="$1"; local p="$2"
    
    local prompt_text=$(printf "$M_ASK_DELETE" "$n" "$p")
    
    MENU_TITLE="删除实例" \
    tui_menu "$prompt_text" \
        "1. 确认删除 (Yes)" \
        "2. 取消 (No)"
        
    if [ $? -ne 0 ]; then MENU_TITLE="删除实例" tui_msgbox "$M_DELETE_CANCEL"; return 1; fi
    
    if [ "$(get_status "$n")" == "RUNNING" ]; then
        stop_srv "$n"
    fi
    
    grep -v "^$n|" "$DATA_FILE" > "${DATA_FILE}.tmp"
    mv "${DATA_FILE}.tmp" "$DATA_FILE"
    
    if [ -d "$p" ]; then rm -rf "$p"; fi
    rm -f "${TRAFFIC_DIR}/${n}_"*.csv
    
    MENU_TITLE="删除实例" tui_msgbox "$(printf "$M_DELETE_OK" "$n")"
    return 0
}

traffic_daemon() {
    if [ "$EUID" -ne 0 ]; then echo "Root only"; exit 1; fi
    if [ "$TRAFFIC_BACKEND" = "auto" ] || [ -z "$TRAFFIC_BACKEND" ]; then
        if command -v iptables >/dev/null 2>&1; then
            local out
            # 直接针对 L4M_STATS 链做兼容性检测，以捕获 nf_tables 的报错
            out=$(iptables -nvxL L4M_STATS 2>&1 || true)
            if echo "$out" | grep -q "use 'nft' tool"; then
                if command -v nft >/dev/null 2>&1; then
                    TRAFFIC_BACKEND="nft"
                else
                    TRAFFIC_BACKEND="unsupported"
                fi
            else
                TRAFFIC_BACKEND="iptables"
            fi
        elif command -v nft >/dev/null 2>&1; then
            TRAFFIC_BACKEND="nft"
        else
            TRAFFIC_BACKEND="none"
        fi
    fi
    if [ "$TRAFFIC_BACKEND" != "iptables" ]; then
        echo "Traffic stats backend not supported on this system." >&2
        exit 0
    fi
    mkdir -p "$TRAFFIC_DIR"
    iptables -N L4M_STATS 2>/dev/null
    if ! iptables -C INPUT -j L4M_STATS 2>/dev/null; then iptables -I INPUT -j L4M_STATS; fi
    if ! iptables -C OUTPUT -j L4M_STATS 2>/dev/null; then iptables -I OUTPUT -j L4M_STATS; fi
    declare -A last_rx; declare -A last_tx
    while true; do
        while IFS='|' read -r n p s port auto; do
            if [ -n "$port" ]; then
                for proto in udp tcp; do
                    if ! iptables -C L4M_STATS -p $proto --dport "$port" 2>/dev/null; then iptables -A L4M_STATS -p $proto --dport "$port"; fi
                    if ! iptables -C L4M_STATS -p $proto --sport "$port" 2>/dev/null; then iptables -A L4M_STATS -p $proto --sport "$port"; fi
                done
            fi
        done < "$DATA_FILE"
        local ts=$(date +%s); local m=$(date +%Y%m)
        local out=$(iptables -nvxL L4M_STATS)
        while IFS='|' read -r n p s port auto; do
            if [ -n "$port" ]; then
                local rx=$(echo "$out" | awk -v p="dpt:$port" '$0 ~ p {sum+=$2} END {print sum+0}')
                local tx=$(echo "$out" | awk -v p="spt:$port" '$0 ~ p {sum+=$2} END {print sum+0}')
                local drx=0; local dtx=0
                if [ -n "${last_rx[$port]}" ]; then
                    drx=$((rx - ${last_rx[$port]})); dtx=$((tx - ${last_tx[$port]}))
                    if [ $drx -lt 0 ]; then drx=$rx; fi; if [ $dtx -lt 0 ]; then dtx=$tx; fi
                fi
                last_rx[$port]=$rx; last_tx[$port]=$tx
                if [ $drx -gt 0 ] || [ $dtx -gt 0 ]; then echo "$ts,$drx,$dtx" >> "${TRAFFIC_DIR}/${n}_${m}.csv"; fi
            fi
        done < "$DATA_FILE"
        sleep 300
    done
}

view_traffic() {
    local n="$1"; local port="$2"
    if [ "$EUID" -ne 0 ]; then MENU_TITLE="$M_OPT_TRAFFIC" tui_msgbox "$M_NEED_ROOT"; return; fi
    if [ "$TRAFFIC_BACKEND" = "auto" ] || [ -z "$TRAFFIC_BACKEND" ]; then
        if command -v iptables >/dev/null 2>&1; then
            local out
            # 直接针对 L4M_STATS 链做兼容性检测，以捕获 nf_tables 的报错
            out=$(iptables -nvxL L4M_STATS 2>&1 || true)
            if echo "$out" | grep -q "use 'nft' tool"; then
                if command -v nft >/dev/null 2>&1; then
                    TRAFFIC_BACKEND="nft"
                else
                    TRAFFIC_BACKEND="unsupported"
                fi
            else
                TRAFFIC_BACKEND="iptables"
            fi
        elif command -v nft >/dev/null 2>&1; then
            TRAFFIC_BACKEND="nft"
        else
            TRAFFIC_BACKEND="none"
        fi
    fi
    if [ "$TRAFFIC_BACKEND" != "iptables" ]; then
        tui_header
        echo -e "$M_TRAFFIC_STATS $n ($port)\n----------------------------------------"
        echo -e "$M_TRAFFIC_UNSUPPORTED"
        echo "----------------------------------------"
        echo -e "$M_PRESS_KEY"
        # 读取任意单键（包括回车），最多等待 10 秒，然后直接返回上级菜单
        read -rsn1 -t 10 k 2>/dev/null || true
        return
    fi
    while true; do
        tui_header; echo -e "$M_TRAFFIC_STATS $n ($port)\n----------------------------------------"
        local r1=$(iptables -nvxL L4M_STATS | awk -v p="dpt:$port" '$0 ~ p {sum+=$2} END {print sum+0}')
        local t1=$(iptables -nvxL L4M_STATS | awk -v p="spt:$port" '$0 ~ p {sum+=$2} END {print sum+0}')
        sleep 1
        local r2=$(iptables -nvxL L4M_STATS | awk -v p="dpt:$port" '$0 ~ p {sum+=$2} END {print sum+0}')
        local t2=$(iptables -nvxL L4M_STATS | awk -v p="spt:$port" '$0 ~ p {sum+=$2} END {print sum+0}')
        echo -e "$M_REALTIME ↓$(numfmt --to=iec --suffix=B/s $((r2-r1)))  ↑$(numfmt --to=iec --suffix=B/s $((t2-t1)))"
        echo "----------------------------------------"
        local f="${TRAFFIC_DIR}/${n}_$(date +%Y%m).csv"
        if [ -f "$f" ]; then
            local today=$(date +%s -d "today 00:00")
            local stats=$(awk -F, -v d="$today" '{tr+=$2; tt+=$3} $1 >= d {dr+=$2; dt+=$3} END {printf "%d %d %d %d", dr, dt, tr, tt}' "$f")
            read dr dt tr tt <<< "$stats"
            echo -e "$M_TODAY ↓$(numfmt --to=iec $dr) ↑$(numfmt --to=iec $dt)"
            echo -e "$M_MONTH ↓$(numfmt --to=iec $tr) ↑$(numfmt --to=iec $tt)"
        else
            echo "$M_NO_HISTORY"
        fi
        echo "----------------------------------------"
        echo -e "$M_PRESS_KEY"; read -n 1 -s -r -t 5 k; if [ -n "$k" ]; then break; fi
    done
}

#=============================================================================
# 9. 依赖管理与换源模块 (Dependency Manager)
#=============================================================================

# 核心依赖列表
# 格式: 通用名称|Debian包名|RHEL包名|描述
DEP_LIST=(
    "tmux|tmux|tmux|多路复用终端"
    "curl|curl|curl|网络传输工具"
    "wget|wget|wget|文件下载工具"
    "tar|tar|tar|归档工具"
    "tree|tree|tree|目录树查看"
    "sed|sed|sed|流编辑器"
    "awk|gawk|gawk|文本处理工具"
    "lsof|lsof|lsof|文件/端口查看"
    "7z|p7zip-full|p7zip|7z压缩支持"
    "unzip|unzip|unzip|Zip解压工具"
    "file|file|file|文件类型检测"
    "whiptail|whiptail|newt|图形化界面支持"
    "lib32gcc|lib32gcc-s1|glibc.i686|32位运行库(GCC)"
    "lib32stdc++|lib32stdc++6|libstdc++.i686|32位运行库(C++)"
    "ca-certificates|ca-certificates|ca-certificates|SSL证书"
)

# 检测依赖状态
# 返回: 0=全部安装, 1=有缺失
check_dep_status_core() {
    local missing=0
    local info_arr=()
    
    # 针对 Debian/Ubuntu 的 lib32gcc 兼容性处理
    local lib32gcc_name="lib32gcc-s1"
    
    if [ -f /etc/os-release ]; then
        # 避免污染全局变量，在一个子 shell 或者使用 local 变量读取
        # 但这里是函数内，直接读取也行，但要注意变量名冲突。
        # 上下文已经有 . /etc/os-release 的逻辑吗？
        # check_dep_status_core 是独立函数。
        local ID=""
        local VERSION_ID=""
        # 使用 grep 提取，避免 source 覆盖可能的全局变量
        ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        VERSION_ID=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        
        if [[ "$ID" == "debian" ]]; then
            local major_ver=$(echo "$VERSION_ID" | cut -d. -f1)
            if [ -n "$major_ver" ] && [ "$major_ver" -le 10 ]; then
                lib32gcc_name="lib32gcc1"
            fi
        elif [[ "$ID" == "ubuntu" ]]; then
             case "$VERSION_ID" in
                "16.04"|"18.04"|"20.04") lib32gcc_name="lib32gcc1" ;;
            esac
        fi
    fi
    
    for item in "${DEP_LIST[@]}"; do
        local name=$(echo "$item" | cut -d'|' -f1)
        local deb_pkg=$(echo "$item" | cut -d'|' -f2)
        local rpm_pkg=$(echo "$item" | cut -d'|' -f3)
        local desc=$(echo "$item" | cut -d'|' -f4)
        
        # 特殊处理 lib32gcc
        if [ "$name" == "lib32gcc" ] && [ -f /etc/debian_version ]; then deb_pkg="$lib32gcc_name"; fi
        
        local status="MISSING"
        local color="${RED}"
        
        # 检查逻辑
        if [[ "$name" == lib* ]] || [[ "$name" == ca-* ]]; then
             # 库文件检查 (简化版: 只要 dpkg/rpm 能查到就算安装)
             if [ -f /etc/debian_version ]; then
                 if dpkg -l | grep -qw "$deb_pkg"; then status="INSTALLED"; color="${GREEN}"; fi
             elif [ -f /etc/redhat-release ]; then
                 if rpm -qa | grep -qw "$rpm_pkg"; then status="INSTALLED"; color="${GREEN}"; fi
             fi
        else
             # 常用命令检查
             if command -v "$name" >/dev/null 2>&1; then status="INSTALLED"; color="${GREEN}"; fi
        fi
        
        if [ "$status" == "MISSING" ]; then ((missing++)); fi
        info_arr+=("${color}[${status}]${NC} ${name} (${desc})")
    done
    
    # 仅在需要显示时输出
    if [ "$1" == "print" ]; then
        local msg_str="依赖安装状态:\n----------------------------------------\n"
        for line in "${info_arr[@]}"; do msg_str+="$line\n"; done
        msg_str+="----------------------------------------\n"
        
        if [ $missing -eq 0 ]; then
            msg_str+="${GREEN}完美！所有依赖已就绪。${NC}"
        else
            msg_str+="${YELLOW}发现 $missing 个缺失依赖。${NC}"
        fi
        
        MENU_TITLE="依赖管理中心" \
        tui_msgbox "$msg_str"
    fi
    
    if [ $missing -eq 0 ]; then return 0; else return 1; fi
}

# 智能安装所有依赖
install_all_deps_smart() {
    if [ "$EUID" -ne 0 ]; then
        MENU_TITLE="依赖安装" tui_msgbox "${RED}安装依赖需要 Root 权限。${NC}\n${YELLOW}请尝试: sudo l4m${NC}"
        return
    fi
    
    echo -e "${CYAN}正在初始化安装进程...${NC}"
    
    local cmd_update=""
    local cmd_install=""
    local pkg_list=""
    
    # 1. 检测包管理器并构建列表
    local dist=""
    local ver=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        dist=$ID
        ver=$VERSION_ID
    fi

    if [ -f /etc/debian_version ]; then
        # 修复潜在的 dpkg 中断
        dpkg --configure -a
        
        # 开启 32 位支持
        dpkg --add-architecture i386
        
        # 智能判断 lib32gcc 版本
        local lib32gcc="lib32gcc-s1"
        
        # Ubuntu 版本判断
        if [[ "$dist" == "ubuntu" ]]; then
            case "$ver" in
                "16.04"|"18.04"|"20.04") lib32gcc="lib32gcc1" ;;
                *) lib32gcc="lib32gcc-s1" ;;
            esac
        # Debian 版本判断
        elif [[ "$dist" == "debian" ]]; then
            # 提取主版本号 (如 11)
            local major_ver=$(echo "$ver" | cut -d. -f1)
            if [ -n "$major_ver" ] && [ "$major_ver" -le 10 ]; then
                lib32gcc="lib32gcc1"
            else
                lib32gcc="lib32gcc-s1"
            fi
        fi
        
        pkg_list="tmux curl wget tar tree sed gawk lsof p7zip-full unzip file whiptail $lib32gcc lib32stdc++6 ca-certificates"
        
        # 允许 update 失败但继续安装 (修复坏源卡死问题)
        cmd_update="apt-get update -qq || echo -e '${YELLOW}部分源更新失败，尝试继续安装...${NC}'"
        # 使用 --fix-missing 尝试修复
        cmd_install="apt-get install -y --fix-missing $pkg_list"
        
    elif [ -f /etc/redhat-release ]; then
        pkg_list="tmux curl wget tar tree sed gawk lsof p7zip unzip file newt glibc.i686 libstdc++.i686"
        cmd_update="yum makecache"
        cmd_install="yum install -y $pkg_list"
    else
        MENU_TITLE="依赖安装" tui_msgbox "${RED}未知的发行版，无法自动安装。${NC}"; return
    fi
    
    echo -e "${YELLOW}Step 1: 更新软件源索引...${NC}"
    eval "$cmd_update"
    
    echo -e "${YELLOW}Step 2: 安装软件包...${NC}"
    if eval "$cmd_install"; then
        # 二次检查: 确保关键依赖确实装上了
        if check_dep_status_core "silent"; then
             MENU_TITLE="依赖安装" \
             tui_msgbox "${GREEN}所有依赖安装成功！${NC}"
        else
             # 针对 lib32gcc1/s1 的最后尝试
             if [ -f /etc/debian_version ]; then
                 echo -e "${CYAN}尝试强制安装 lib32gcc 变体...${NC}"
                 apt-get install -y lib32gcc-s1 lib32gcc1 2>/dev/null || true
             fi
             
             if check_dep_status_core "silent"; then
                 MENU_TITLE="依赖安装" \
                 tui_msgbox "${GREEN}修复成功！所有依赖已就绪。${NC}"
             else
                 MENU_TITLE="依赖安装" \
                 tui_msgbox "${YELLOW}部分依赖似乎仍未安装成功。\n建议尝试 [换源] 功能修复网络问题后重试。${NC}"
             fi
        fi
    else
        MENU_TITLE="依赖安装" \
        tui_msgbox "${RED}安装过程中出现错误。\n建议尝试 [换源] 功能修复网络问题。${NC}"
    fi
    
    # read -n 1 -s -r # tui_msgbox 已经包含了等待
}

# 换源功能
change_repo_source() {
    if [ "$EUID" -ne 0 ]; then MENU_TITLE="智能换源" tui_msgbox "${RED}需 Root 权限${NC}"; return; fi
    
    tui_header
    echo -e "${CYAN}Linux 智能换源助手${NC}"
    echo "----------------------------------------"
    
    # 1. 识别发行版
    local dist=""
    local code=""
    local ver=""
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        dist=$ID
        code=$VERSION_CODENAME
        ver=$VERSION_ID
    fi
    
    echo -e "检测到系统: ${GREEN}${dist} ${ver} (${code})${NC}"
    
    if [[ "$dist" != "debian" && "$dist" != "ubuntu" && "$dist" != "centos" ]]; then
        MENU_TITLE="智能换源" tui_msgbox "${RED}当前仅支持 Debian / Ubuntu / CentOS 自动换源。${NC}"
        return
    fi
    
    local choice
    MENU_TITLE="Linux 智能换源助手" \
    tui_menu "检测到系统: ${GREEN}${dist} ${ver} (${code})${NC}\n请选择要更换的国内源:" \
        "阿里云 (Aliyun) - 推荐" \
        "清华大学 (TUNA)" \
        "腾讯云 (Tencent)" \
        "还原官方源 (Restore)" \
        "返回"
    
    case $? in
        0) choice="1" ;;
        1) choice="2" ;;
        2) choice="3" ;;
        3) choice="4" ;;
        *) return ;;
    esac
    
    local domain=""
    case "$choice" in
        1) domain="mirrors.aliyun.com" ;;
        2) domain="mirrors.tuna.tsinghua.edu.cn" ;;
        3) domain="mirrors.cloud.tencent.com" ;;
        4) domain="restore" ;;
        *) return ;;
    esac
    
    local file="/etc/apt/sources.list"
    if [ "$dist" == "centos" ]; then file="/etc/yum.repos.d/CentOS-Base.repo"; fi
    
    # 备份
    if [ ! -f "${file}.bak" ]; then cp "$file" "${file}.bak"; fi
    
    echo -e "${YELLOW}正在配置源...${NC}"
    
    if [ "$domain" == "restore" ]; then
        if [ -f "${file}.bak" ]; then cp "${file}.bak" "$file"; MENU_TITLE="换源结果" tui_msgbox "${GREEN}已还原。${NC}"; else MENU_TITLE="换源结果" tui_msgbox "${RED}无备份文件。${NC}"; fi
    else
        if [ "$dist" == "debian" ]; then
            # Debian 智能生成
            echo "deb http://${domain}/debian/ ${code} main contrib non-free" > "$file"
            echo "deb http://${domain}/debian/ ${code}-updates main contrib non-free" >> "$file"
            echo "deb http://${domain}/debian/ ${code}-backports main contrib non-free" >> "$file"
            echo "deb http://${domain}/debian-security ${code}-security main contrib non-free" >> "$file"
            
        elif [ "$dist" == "ubuntu" ]; then
            # Ubuntu 智能生成
            echo "deb http://${domain}/ubuntu/ ${code} main restricted universe multiverse" > "$file"
            echo "deb http://${domain}/ubuntu/ ${code}-updates main restricted universe multiverse" >> "$file"
            echo "deb http://${domain}/ubuntu/ ${code}-backports main restricted universe multiverse" >> "$file"
            echo "deb http://${domain}/ubuntu/ ${code}-security main restricted universe multiverse" >> "$file"
            
        elif [ "$dist" == "centos" ]; then
            # CentOS 智能生成 (支持 7 和 8-Stream)
            local centos_ver=$(echo "$ver" | cut -d. -f1)
            
            if [ "$centos_ver" == "7" ]; then
                case "$domain" in
                    "mirrors.aliyun.com")
                         curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
                         ;;
                    "mirrors.cloud.tencent.com")
                         curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.cloud.tencent.com/repo/centos7_base.repo
                         ;;
                    "mirrors.tuna.tsinghua.edu.cn")
                         # Tuna 不提供直接下载，使用 sed 修改
                         sed -e 's|^mirrorlist=|#mirrorlist=|g' \
                             -e 's|^#baseurl=http://mirror.centos.org/centos|baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos|g' \
                             -i /etc/yum.repos.d/CentOS-Base.repo
                         ;;
                esac
            elif [ "$centos_ver" == "8" ]; then
                # 假设是 CentOS Stream 8 (因为 CentOS 8 已EOL)
                # 使用 sed 批量替换所有 repo 文件
                local proto="http"
                if [ "$domain" == "mirrors.tuna.tsinghua.edu.cn" ]; then proto="https"; fi
                
                # 备份原始文件已经在上面做了
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
                sed -i "s|#baseurl=http://mirror.centos.org|baseurl=${proto}://${domain}|g" /etc/yum.repos.d/CentOS-*.repo
                
                # Tuna 特殊处理
                if [ "$domain" == "mirrors.tuna.tsinghua.edu.cn" ]; then
                     sed -i "s|baseurl=https://${domain}/|baseurl=https://${domain}/centos-stream/|g" /etc/yum.repos.d/CentOS-*.repo
                fi
            else
                 MENU_TITLE="换源结果" tui_msgbox "${YELLOW}未知的 CentOS 版本: $ver\n请手动配置。${NC}"
                 return
            fi
        fi
        MENU_TITLE="换源结果" tui_msgbox "${GREEN}源文件已更新。${NC}\n正在刷新缓存..."
    fi
    
    echo -e "${CYAN}正在刷新缓存...${NC}"
    if [ "$dist" == "centos" ]; then
        yum makecache
    else
        apt-get update
    fi
    
    MENU_TITLE="换源结果" tui_msgbox "${GREEN}操作完成。${NC}"
}

dep_manager_menu() {
    while true; do
        tui_menu "依赖管理中心" "查看依赖安装状态" "一键安装/修复所有依赖" "更换系统软件源 (修复下载慢)" "返回"
        case $? in
            0) check_dep_status_core "print" ;; # check_dep_status_core 内部已使用 tui_msgbox
            1) install_all_deps_smart ;; # 内部已使用 tui_msgbox
            2) change_repo_source ;;
            *) return ;;
        esac
    done
}

uninstall_menu() {
    MENU_TITLE="$M_UNINSTALL_MENU"
    tui_menu "$M_UNINSTALL_MENU" \
        "$M_UN_CONF_ONLY" \
        "$M_UN_INST_ONLY" \
        "$M_UN_FULL" \
        "$M_RETURN"
    
    local choice=$?
    if [ $choice -eq 3 ] || [ $choice -eq 255 ]; then return; fi
    
    # Confirm
    MENU_TITLE="$M_UNINSTALL_MENU"
    tui_menu "$M_UN_CONFIRM" "1. Yes" "2. No"
    if [ $? -ne 0 ]; then return; fi
    
    case $choice in
        0) # Reset Config
            rm -f "$CONFIG_FILE" "$PLUGIN_CONFIG"
            MENU_TITLE="$M_UNINSTALL_MENU" tui_msgbox "$M_UN_DONE"
            exit 0
            ;;
        1) # Delete Instances
            if [ -f "$DATA_FILE" ]; then
                while IFS='|' read -r n p s port auto; do
                    if [ -n "$n" ]; then stop_srv "$n"; fi
                done < "$DATA_FILE"
                
                while IFS='|' read -r n p s port auto; do
                    if [ -n "$p" ] && [ -d "$p" ]; then rm -rf "$p"; fi
                done < "$DATA_FILE"
            fi
            
            > "$DATA_FILE"
            rm -f "$TRAFFIC_DIR"/*.csv
            
            MENU_TITLE="$M_UNINSTALL_MENU" tui_msgbox "$M_UN_DONE"
            ;;
        2) # Full Uninstall
            if [ -f "$DATA_FILE" ]; then
                while IFS='|' read -r n p s port auto; do
                    if [ -n "$n" ]; then stop_srv "$n"; fi
                done < "$DATA_FILE"
                
                while IFS='|' read -r n p s port auto; do
                    if [ -n "$p" ] && [ -d "$p" ]; then rm -rf "$p"; fi
                done < "$DATA_FILE"
            fi
            
            if [ -d "$FINAL_ROOT" ]; then rm -rf "$FINAL_ROOT"; fi
            
            rm -f "/usr/bin/l4m" "/usr/bin/l4m-update" "$HOME/bin/l4m" "$HOME/bin/l4m-update"
            
            if [ "$EUID" -eq 0 ]; then
                systemctl disable --now l4m-resume.service 2>/dev/null
                systemctl disable --now l4m-monitor.service 2>/dev/null
                rm -f /etc/systemd/system/l4m-resume.service /etc/systemd/system/l4m-monitor.service
                systemctl daemon-reload
            else
                crontab -l 2>/dev/null | grep -v "l4m resume" | crontab -
            fi
            
            echo -e "$M_UN_FULL_DONE"
            exit 0
            ;;
    esac
}

#=============================================================================
# 8. Main Entry
#=============================================================================
main() {
    chmod +x "$0"
    
    # 快速通道：如果参数是 update，直接调用自我更新逻辑，不加载 TUI
    if [ "$1" == "update" ]; then
        self_update
        exit 0
    fi

    case "$1" in
        "install") install_smart; exit 0 ;;
        "resume") resume_all; exit 0 ;;
        "monitor") traffic_daemon; exit 0 ;;
    esac
    
    if [ ! -f "$CONFIG_FILE" ]; then
        MENU_TITLE="=== L4D2 Manager (L4M) ===" \
        tui_menu "Please select language / 请选择语言:" \
            "1. English" \
            "2. 简体中文"
            
        local choice=$?
        local l="1"
        if [ $choice -eq 1 ]; then l="2"; fi
        
        # 确保目录存在
        mkdir -p "$(dirname "$CONFIG_FILE")"
        if [ "$l" == "2" ]; then echo "zh" > "$CONFIG_FILE"; else echo "en" > "$CONFIG_FILE"; fi
        
        if [ "$l" == "2" ] && [ "$EUID" -eq 0 ]; then
             if [ -f /etc/debian_version ]; then
                 echo -e "${YELLOW}Configuring Chinese Locale...${NC}"
                 apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq locales >/dev/null 2>&1
                 sed -i 's/# zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen 2>/dev/null
                 locale-gen zh_CN.UTF-8 >/dev/null 2>&1
                 export LANG=zh_CN.UTF-8
             fi
        fi
    fi
    # 使用双引号包裹 cat 输出，防止参数传递错误
    if [ -f "$CONFIG_FILE" ]; then load_i18n "$(cat "$CONFIG_FILE")"; else load_i18n "en"; fi
    
    if [[ "$INSTALL_TYPE" == "temp" ]]; then
        local exist_path=""
        if [ "$EUID" -eq 0 ] && [ -f "$SYSTEM_INSTALL_DIR/l4m" ]; then exist_path="$SYSTEM_INSTALL_DIR/l4m";
        elif [ -f "$USER_INSTALL_DIR/l4m" ]; then exist_path="$USER_INSTALL_DIR/l4m"; fi
        
        if [ -n "$exist_path" ]; then
            echo -e "${GREEN}$M_FOUND_EXISTING${NC}"; sleep 1; exec "$exist_path" "$@"
        fi

        MENU_TITLE="L4D2 Manager (L4M)" \
        tui_menu "$M_WELCOME\n$M_TEMP_RUN\n\n$M_REC_INSTALL\n$M_F_PERSIST\n$M_F_ACCESS\n$M_F_ADV" \
            "1. 立即安装 (Install)" \
            "2. 临时运行 (Temp Mode)"
            
        if [ $? -eq 0 ]; then install_smart; exit 0; fi
        echo -e "$M_TEMP_MODE"; sleep 1
    fi
    
    check_deps
    if [ ! -f "$DATA_FILE" ]; then touch "$DATA_FILE"; fi
    ensure_remote_version_cached
    
    while true; do
        local remote_ver_cached=""
        if [ -f "$REMOTE_VERSION_CACHE" ]; then
            remote_ver_cached=$(head -n1 "$REMOTE_VERSION_CACHE" 2>/dev/null)
        fi
        local main_desc=""
        local ver_line="${M_VER_LOCAL} v${L4M_VERSION}"
        local title_tag=""
        if [ -n "$remote_ver_cached" ]; then
            if [ "$remote_ver_cached" = "$L4M_VERSION" ]; then
                main_desc="$M_MAIN_MENU\n$ver_line\n${M_VER_REMOTE} v${remote_ver_cached} ${M_VER_REMOTE_UP_TO_DATE}"
                title_tag="$M_VER_TAG_UP_TO_DATE"
            else
                main_desc="$M_MAIN_MENU\n$ver_line\n${M_VER_REMOTE} v${remote_ver_cached} ${M_VER_REMOTE_NEED_UPDATE}"
                title_tag="$M_VER_TAG_NEED_UPDATE"
            fi
        else
            main_desc="$M_MAIN_MENU\n$ver_line\n$M_VER_REMOTE_UNKNOWN"
            title_tag="$M_VER_TAG_UNKNOWN"
        fi
        MENU_TITLE="L4D2 Manager (L4M) v${L4M_VERSION} ${title_tag}"
        tui_menu "$main_desc" "$M_DEPLOY" "$M_MANAGE" "$M_DOWNLOAD_PACKAGES" "$M_DEPS" "$M_UPDATE" "$M_LANG" "$M_UNINSTALL_MENU" "$M_EXIT"
        case $? in
            0) deploy_wizard ;; 1) manage_menu ;; 2) download_packages ;; 3) dep_manager_menu ;; 4) self_update ;; 5) change_lang ;; 6) uninstall_menu ;; 7|255) exit 0 ;;
        esac
    done
}

main "$@"
