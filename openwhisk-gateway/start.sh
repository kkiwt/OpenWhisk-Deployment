#!/bin/bash

# Bảng màu cho Console
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/venv}"
cd "$SCRIPT_DIR"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi
GATEWAY_BIND_HOST="${GATEWAY_BIND_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}🚀 KÍCH HOẠT HỆ THỐNG GATEWAY SERVERLESS K3S 🚀${NC}"
echo -e "${CYAN}=================================================${NC}"

# 1. Kiểm tra và tự động tạo venv nếu chưa tồn tại
if [ ! -d "$VENV_DIR" ]; then
    echo -e "${YELLOW}⚠️ Chưa có môi trường ảo. Đang tự động tạo thư mục venv...${NC}"
    python3 -m venv "$VENV_DIR"
fi

echo -e "${GREEN}📦 Đang kích hoạt môi trường ảo (venv)...${NC}"
source "$VENV_DIR/bin/activate"

# 2. Cài đặt âm thầm các thư viện cần thiết (-q là quiet, không in rác ra màn hình)
echo -e "${GREEN}🔍 Kiểm tra và cập nhật thư viện lõi...${NC}"
pip install -q fastapi uvicorn httpx pydantic rich requests

# 3. Lấy IP mạng Tailscale (nếu không có tự fallback về 127.0.0.1)
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")

echo -e "\n${GREEN}✅ HOÀN TẤT TÙY CHỈNH! HỆ THỐNG ĐÃ SẴN SÀNG.${NC}"
echo -e "🔗 Địa chỉ API cho đồng đội: ${YELLOW}http://${TAILSCALE_IP}:8080${NC}"
echo -e "🖥️ Bảng điều khiển TUI     : ${YELLOW}python '$SCRIPT_DIR/dashboard.py'${NC}"
echo -e "🌍 Bảng điều khiển Web     : ${YELLOW}$SCRIPT_DIR/dashboard.html${NC}\n"

# Khởi chạy Gateway
echo -e "${CYAN}🌐 Đang khởi chạy Uvicorn Server (Nhấn Ctrl+C để tắt ngầm)...${NC}"
uvicorn gateway:app --host "$GATEWAY_BIND_HOST" --port "$GATEWAY_PORT" --workers 1
