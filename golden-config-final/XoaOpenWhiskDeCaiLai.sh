#!/bin/bash
# Luôn chạy trong thư mục chứa script này (Desktop) để lệnh "rm -rf openwhisk-deploy-kube" xóa đúng chỗ
cd "$(dirname "$(readlink -f "$0")")"

echo "⚠️ CẢNH BÁO: Quá trình này sẽ XÓA SẠCH cụm OpenWhisk và dữ liệu liên quan!"
read -p "Bác có chắc chắn muốn tiếp tục không? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "🛟 0/5: Cứu các file Golden nếu lỡ để trong thư mục openwhisk-deploy-kube..."
    if [ -d openwhisk-deploy-kube ]; then
        mkdir -p golden
        for f in golden-values.yaml install-golden.sh test-golden.sh TestMoi.sh HUONG-DAN.md; do
            if [ -f "openwhisk-deploy-kube/$f" ] && [ ! -f "golden/$f" ]; then
                mv "openwhisk-deploy-kube/$f" "golden/$f" && echo "   ➜ đã chuyển $f sang thư mục golden/"
            fi
        done
    fi
    # golden.lock và các báo cáo gắn với chart cũ nên bỏ đi, máy gốc sẽ tạo lại
    rm -f golden/golden.lock golden/images-*.txt golden/golden-report-*.txt golden/golden-debug-*.txt

    echo "🧹 1/5: Gỡ cài đặt Helm Release của OpenWhisk..."
    helm uninstall owdev -n openwhisk || true

    echo "🗑 2/5: Xóa bỏ hoàn toàn Kubernetes Namespace..."
    kubectl delete namespace openwhisk --force --grace-period=0 || true

    echo "🔥 3/5: Đập bỏ cụm K3d Cluster..."
    k3d cluster delete openwhisk-cluster || true

    echo "📁 4/5: Dọn dẹp các thư mục rác và file cấu hình..."
    rm -rf openwhisk-deploy-kube
    rm -f my-values.yaml
    rm -f ~/.wskprops
    rm -f get_helm.sh get-docker.sh

    echo "🐳 5/5: Dọn dẹp hệ thống Docker (Xóa container rác, network, image treo)..."
    # Lệnh này cực kỳ quan trọng để giải phóng ổ cứng sau khi test
    docker system prune -a --volumes -f

    echo "============================================================"
    echo "✅ ĐÃ XÓA SẠCH DẤU VẾT CỦA OPENWHISK!"
    echo "   (các file Golden được giữ nguyên trong thư mục golden/)"
    echo "Nếu bác muốn gỡ luôn cả các tool CLI (kubectl, helm, k3d, wsk), hãy chạy:"
    echo "sudo rm /usr/local/bin/kubectl /usr/local/bin/helm /usr/local/bin/k3d /usr/local/bin/wsk"
    echo "============================================================"
fi
