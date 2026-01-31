#!/bin/bash
# fnOS 安全检测与清理脚本 v2.0
# 用于检测和清除已知的恶意文件，不会破坏飞牛系统
# 使用方法: sudo bash fnos_security_check.sh
# 更新日期: 2026-01-31

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "   fnOS 安全检测与清理脚本 v2.0"
echo "   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 sudo 运行此脚本${NC}"
    exit 1
fi

INFECTED=0
CLEANED=0

# 已知恶意文件列表
MALWARE_FILES=(
    "/usr/sbin/gots"
    "/usr/bin/gots"
    "/sbin/gots"
    "/usr/bin/nginx"
    "/usr/bin/dockers"
    "/usr/local/bin/gostc"
    "/tmp/.X11-unix/gots"
    "/var/tmp/gots"
)

# 已知恶意服务
MALWARE_SERVICES=(
    "/etc/systemd/system/dockers.service"
    "/etc/systemd/system/nginx.service"
    "/etc/systemd/system/gostc.service"
)

# 已知恶意域名/IP
MALWARE_SIGNATURES=(
    "45.95.212.102"
    "151.240.13.91"
    "killaurasleep.top"
)

echo -e "${YELLOW}[1/6] 检测已知恶意文件...${NC}"
for filepath in "${MALWARE_FILES[@]}"; do
    if [ -f "$filepath" ]; then
        echo -e "${RED}  [!] 发现恶意文件: $filepath${NC}"
        ls -la "$filepath" 2>/dev/null || true
        INFECTED=1
        
        chattr -ia "$filepath" 2>/dev/null || true
        if rm -f "$filepath" 2>/dev/null; then
            echo -e "${GREEN}  [✓] 已删除: $filepath${NC}"
            ((CLEANED++))
        else
            echo -e "${RED}  [✗] 删除失败: $filepath${NC}"
        fi
    fi
done
[ $INFECTED -eq 0 ] && echo -e "${GREEN}  [✓] 未发现恶意文件${NC}"

echo ""
echo -e "${YELLOW}[2/6] 检测恶意服务...${NC}"
SERVICE_INFECTED=0
for svcfile in "${MALWARE_SERVICES[@]}"; do
    if [ -f "$svcfile" ]; then
        svcname=$(basename "$svcfile")
        echo -e "${RED}  [!] 发现恶意服务: $svcname${NC}"
        SERVICE_INFECTED=1
        INFECTED=1
        
        systemctl stop "$svcname" 2>/dev/null || true
        systemctl disable "$svcname" 2>/dev/null || true
        chattr -ia "$svcfile" 2>/dev/null || true
        if rm -f "$svcfile" 2>/dev/null; then
            echo -e "${GREEN}  [✓] 已删除: $svcfile${NC}"
            ((CLEANED++))
        fi
    fi
done
[ $SERVICE_INFECTED -eq 0 ] && echo -e "${GREEN}  [✓] 未发现恶意服务${NC}"

echo ""
echo -e "${YELLOW}[3/6] 检测 /etc/rc.local 恶意启动项...${NC}"
if [ -f "/etc/rc.local" ]; then
    if grep -qE "(gots|dockers)" /etc/rc.local 2>/dev/null; then
        echo -e "${RED}  [!] 发现恶意启动命令:${NC}"
        grep -E "(gots|dockers)" /etc/rc.local
        INFECTED=1
        
        chattr -ia /etc/rc.local 2>/dev/null || true
        echo '#!/bin/bash
exit 0' > /etc/rc.local
        chmod +x /etc/rc.local
        echo -e "${GREEN}  [✓] 已清理 /etc/rc.local${NC}"
        ((CLEANED++))
    else
        echo -e "${GREEN}  [✓] rc.local 正常${NC}"
    fi
fi

echo ""
echo -e "${YELLOW}[4/6] 检测可疑进程...${NC}"
SUSPICIOUS_PROCS=$(ps aux | grep -E "(gots|dockers)" | grep -v grep | grep -v "$0" || true)
if [ -n "$SUSPICIOUS_PROCS" ]; then
    echo -e "${RED}  [!] 发现可疑进程:${NC}"
    echo "$SUSPICIOUS_PROCS"
    INFECTED=1
    pkill -9 gots 2>/dev/null && echo -e "${GREEN}  [✓] 已终止 gots${NC}" || true
    pkill -9 dockers 2>/dev/null && echo -e "${GREEN}  [✓] 已终止 dockers${NC}" || true
else
    echo -e "${GREEN}  [✓] 未发现可疑进程${NC}"
fi

echo ""
echo -e "${YELLOW}[5/6] 检测恶意网络连接...${NC}"
NET_INFECTED=0
for sig in "${MALWARE_SIGNATURES[@]}"; do
    if netstat -tunp 2>/dev/null | grep -q "$sig"; then
        echo -e "${RED}  [!] 发现连接到恶意地址: $sig${NC}"
        NET_INFECTED=1
        INFECTED=1
    fi
done
[ $NET_INFECTED -eq 0 ] && echo -e "${GREEN}  [✓] 网络连接正常${NC}"

echo ""
echo -e "${YELLOW}[6/6] 检测定时任务...${NC}"
CRON_INFECTED=0
for crontab in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*; do
    if [ -f "$crontab" ] 2>/dev/null; then
        if grep -qE "(gots|dockers|killaurasleep)" "$crontab" 2>/dev/null; then
            echo -e "${RED}  [!] 发现可疑定时任务: $crontab${NC}"
            CRON_INFECTED=1
            INFECTED=1
        fi
    fi
done
[ $CRON_INFECTED -eq 0 ] && echo -e "${GREEN}  [✓] 定时任务正常${NC}"

# 重载systemd
systemctl daemon-reload 2>/dev/null || true

echo ""
echo "=========================================="
if [ $INFECTED -eq 0 ]; then
    echo -e "${GREEN}[结果] 系统安全，未发现恶意文件${NC}"
else
    if [ $CLEANED -gt 0 ]; then
        echo -e "${YELLOW}[结果] 已清理 $CLEANED 个恶意项目${NC}"
    fi
    echo -e "${RED}[重要] 请立即升级 fnOS 到 1.1.15 版本！${NC}"
    echo -e "${RED}[重要] 请关闭 5666/5777 端口的公网映射！${NC}"
fi
echo "=========================================="

echo ""
echo -e "${YELLOW}运行官方检测脚本...${NC}"
curl -fsSL http://static2.fnnas.com/aptfix/listautostart.sh 2>/dev/null | bash || echo "官方脚本执行失败"

echo ""
echo "检测完成。"
