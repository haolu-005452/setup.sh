#!/bin/bash

DB_DIR="/opt/hyperlane_db_base"
HYPERLANE_CONTAINER_NAME="hyperlane"
VALIDATOR_COUNT=0  # 动态管理创建的验证器数量

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本！"
    exit 1
fi

# 检查并创建数据库目录
if [ ! -d "$DB_DIR" ]; then
    mkdir -p "$DB_DIR" && chmod -R 777 "$DB_DIR" || {
        echo "创建数据库目录失败: $DB_DIR"
        exit 1
    }
    echo "数据库目录已创建: $DB_DIR"
fi

# 安装 Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "安装 Docker..."
        apt-get update
        apt-get install -y docker.io || {
            echo "安装 Docker 失败！"
            exit 1
        }
        systemctl start docker
        systemctl enable docker
        echo "Docker 已安装！"
    else
        echo "Docker 已安装，跳过此步骤。"
    fi
}

# 安装 Node.js 和 NVM
install_nvm_and_node() {
    if ! command -v nvm &> /dev/null; then
        echo "安装 NVM..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash || {
            echo "安装 NVM 失败！"
            exit 1
        }
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        echo "NVM 安装完成！"
    fi

    if ! command -v node &> /dev/null; then
        echo "安装 Node.js v20..."
        nvm install 20 || {
            echo "安装 Node.js 失败！"
            exit 1
        }
        echo "Node.js 安装完成！"
    fi
}

# 安装 Hyperlane
install_hyperlane() {
    if ! command -v hyperlane &> /dev/null; then
        echo "安装 Hyperlane CLI..."
        npm install -g @hyperlane-xyz/cli || {
            echo "安装 Hyperlane CLI 失败！"
            exit 1
        }
        echo "Hyperlane CLI 安装完成！"
    fi

    if ! docker images | grep -q 'gcr.io/abacus-labs-dev/hyperlane-agent'; then
        echo "拉取 Hyperlane 镜像..."
        docker pull --platform linux/amd64 gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 || {
            echo "拉取 Hyperlane 镜像失败！"
            exit 1
        }
        echo "Hyperlane 镜像拉取完成！"
    fi
}

# 启动多个验证器并动态记录数量
start_multiple_validators() {
    local num_validators=$1
    local private_key=$2
    local rpc_url=$3
    local s3_bucket=$4  # S3 存储桶名称

    # 记录启动的验证器数量
    VALIDATOR_COUNT=$num_validators

    for ((i = 1; i <= num_validators; i++)); do
        local validator_name="hyperlane-validator-$i"
        local checkpoint_folder="validator-$i"

        echo "启动验证器 $validator_name..."

        docker run -d \
            --name "$validator_name" \
            --mount type=bind,source="$DB_DIR",target=/hyperlane_db_base \
            --restart unless-stopped \
            --health-cmd="curl --fail http://localhost:8080/health || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 \
            ./validator \
            --db /hyperlane_db_base \
            --originChainName base \
            --reorgPeriod 1 \
            --validator.id "$validator_name" \
            --checkpointSyncer.type s3 \
            --checkpointSyncer.bucket "$s3_bucket" \
            --checkpointSyncer.folder "$checkpoint_folder" \
            --validator.key "$private_key" \
            --chains.base.signer.key "$private_key" \
            --chains.base.customRpcUrls "$rpc_url" &

        echo "验证器 $validator_name 已启动，并使用文件夹 $checkpoint_folder 来存储检查点数据。"
    done
}

# 查看容器日志
view_container_log() {
    read -p "请输入验证器名称 (例如: hyperlane-validator-1): " validator_name

    if docker ps -a | grep -q "$validator_name"; then
        echo "显示 $validator_name 容器日志："
        docker logs --tail 100 -f "$validator_name"
    else
        echo "容器 $validator_name 未运行，无法查看日志！"
    fi
}

# 卸载 Hyperlane
uninstall_hyperlane() {
    read -p "请输入验证器名称 (例如: hyperlane-validator-1): " validator_name

    if docker ps -a | grep -q "$validator_name"; then
        echo "正在停止并删除 $validator_name 容器..."
        docker stop "$validator_name"
        docker rm "$validator_name"
        echo "$validator_name 容器已卸载。"
    else
        echo "$validator_name 容器不存在，跳过此步骤。"
    fi

    echo "卸载完成（未移除依赖）。"
}

# 监控所有容器健康状态
monitor_container_health() {
    for i in $(seq 1 $VALIDATOR_COUNT); do
        container_name="hyperlane-validator-$i"
        health_status=$(docker inspect --format '{{.State.Health.Status}}' "$container_name")
        if [ "$health_status" != "healthy" ]; then
            echo "$container_name 状态异常，状态为: $health_status" | mail -s "Hyperlane 验证器警告" admin@example.com
        fi
    done
}

# 定时任务：每半小时检查一次所有验证器的健康状态
setup_health_check_cron() {
    (crontab -l 2>/dev/null; echo "*/30 * * * * /path/to/this/script.sh monitor_container_health") | crontab -
}

# 主菜单
main_menu() {
    while true; do
        echo "================= Hyperlane 管理脚本 ================="
        echo "1) 安装并启动多个验证器"
        echo "2) 查看容器日志"
        echo "3) 卸载验证器"
        echo "4) 监控所有验证器健康状态"
        echo "5) 设置健康检查定时任务"
        echo "6) 退出脚本"
        echo "====================================================="
        read -p "请输入选项: " choice
        case $choice in
            1)
                read -p "请输入要启动的验证器数量: " num_validators
                read -p "请输入私钥 (格式：0x+64位十六进制字符): " private_key
                read -p "请输入 RPC URL: " rpc_url
                read -p "请输入 S3 存储桶名称: " s3_bucket
                start_multiple_validators "$num_validators" "$private_key" "$rpc_url" "$s3_bucket"
                ;;
            2) view_container_log ;;
            3) uninstall_hyperlane ;;
            4) monitor_container_health ;;
            5) setup_health_check_cron ;;
            6) exit 0 ;;
            *) echo "无效选项，请重试！" ;;
        esac
    done
}

main_menu
