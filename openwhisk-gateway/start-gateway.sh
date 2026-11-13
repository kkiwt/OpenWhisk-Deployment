#!/usr/bin/env bash
# =====================================================================
# Script tự động kích hoạt venv, kiểm tra file .env và khởi chạy Gateway
# =====================================================================
set -Eeuo pipefail

GATEWAY_DIR="D:/OpenWhisk-Deployment/openwhisk-gateway"
cd "$GATEWAY_DIR" || { echo "❌ Không tìm thấy thư mục gateway"; exit 1; }

echo "1/3 Kiểm tra môi trường ảo (venv)..."
if [ ! -d "venv" ]; then
    echo "⚠️ Chưa có thư mục venv. Đang tiến hành tạo mới..."
    python -m venv venv
fi

# Kích hoạt venv tùy theo hệ điều hành (Git Bash / PowerShell)
if [ -f "venv/Scripts/activate" ]; then
    source venv/Scripts/activate
elif [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
else
    echo "❌ Không tìm thấy file kích hoạt venv!"
    exit 1
fi

echo "2/3 Kiểm tra gói phụ thuộc và file cấu hình .env..."
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example .env
        echo "⚠️ Đã tạo file .env từ .env.example. Vui lòng cập nhật lại thông tin URL và Auth!"
    else
        echo "❌ Thiếu file .env và .env.example!"
        exit 1
    fi
fi

# Cài đặt hoặc cập nhật nhanh các gói cần thiết nếu chưa có
pip install --quiet --upgrade pip
pip install --quiet fastapi uvicorn httpx pydantic

echo "3/3 Khởi chạy OpenWhisk Multi-Cluster Gateway qua Uvicorn..."
echo "============================================================"
python -m uvicorn gateway:app --host 0.0.0.0 --port 8080 --reload