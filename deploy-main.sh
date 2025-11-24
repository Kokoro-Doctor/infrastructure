#!/bin/bash
# =================================================================
# MAIN DEPLOYMENT SCRIPT
# Upload this to GitHub or S3 as: deploy-main.sh
# =================================================================

set -e
exec > >(tee -a /var/log/kokoro-deploy.log) 2>&1

# === CONFIG ===
SSL_CERT_PATH="/etc/ssl/kokoro"
S3_BUCKET="s3://kokoro-doctor"
DOMAIN="kokoro.doctor"
FRONTEND_DIR="/home/ubuntu/frontend"
APP_DIR="$FRONTEND_DIR/KokoroDoctor"
RAG_DIR="/home/ubuntu/rag_backend"
NODE_VERSION="18"
EXPECTED_EIP="13.203.1.165"

# === FUNCTIONS ===

log() { echo "$(date '+%H:%M:%S') ✓ $1"; }
err() { echo "$(date '+%H:%M:%S') ✗ $1" >&2; }

setup_env() {
    log "Setting up environment"
    export HOME=/home/ubuntu
    export NVM_DIR="$HOME/.nvm"
    
    if ! grep -q "NVM_DIR" /home/ubuntu/.bashrc; then
        cat >> /home/ubuntu/.bashrc << 'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export PATH=$HOME/.nvm/versions/node/v18/bin:$PATH
EOF
    fi
    source /home/ubuntu/.bashrc 2>/dev/null || true
}

install_node() {
    log "Installing Node.js $NODE_VERSION"
    
    if sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; command -v node' &>/dev/null; then
        log "Node.js already installed"
        return 0
    fi

    sudo -u ubuntu bash << 'NODESETUP'
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 18
nvm use 18
nvm alias default 18
NODESETUP

    export NVM_DIR="/home/ubuntu/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

install_pm2() {
    log "Installing PM2"
    
    export NVM_DIR="/home/ubuntu/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    sudo -u ubuntu bash << 'PM2SETUP'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
npm install -g pm2 expo-cli
pm2 startup systemd -u ubuntu --hp /home/ubuntu
PM2SETUP

    # Execute the startup command
    sudo env PATH=$PATH:/home/ubuntu/.nvm/versions/node/v18/bin \
        /home/ubuntu/.nvm/versions/node/v18/lib/node_modules/pm2/bin/pm2 startup systemd -u ubuntu --hp /home/ubuntu
}

wait_eip() {
    log "Waiting for Elastic IP"
    local retries=20
    while [ $retries -gt 0 ]; do
        local ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
        [[ "$ip" == "$EXPECTED_EIP" ]] && { log "EIP attached: $ip"; return 0; }
        sleep 30
        ((retries--))
    done
    err "EIP timeout"
}

setup_nginx() {
    log "Setting up Nginx"
    
    apt-get update -y
    apt-get install -y nginx awscli
    
    mkdir -p /etc/nginx/sites-{available,enabled} $SSL_CERT_PATH
    chmod 700 $SSL_CERT_PATH

    log "Downloading SSL certificates"
    aws s3 cp $S3_BUCKET/ssl/kokoro.doctor.fullchain.pem $SSL_CERT_PATH/ 2>/dev/null || err "SSL cert failed"
    aws s3 cp $S3_BUCKET/ssl/kokoro.doctor.key $SSL_CERT_PATH/ 2>/dev/null || err "SSL key failed"

    cat > /etc/nginx/sites-available/default << 'NGINXCONF'
server {
    listen 80;
    server_name kokoro.doctor www.kokoro.doctor;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name kokoro.doctor www.kokoro.doctor;
    ssl_certificate /etc/ssl/kokoro/kokoro.doctor.fullchain.pem;
    ssl_certificate_key /etc/ssl/kokoro/kokoro.doctor.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_connect_timeout 10s;
    }
    location /chat {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
    }
    location /ollama/ {
        proxy_pass http://127.0.0.1:11434/;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
    }
}
NGINXCONF

    nginx -t
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
    systemctl enable nginx
    systemctl restart nginx
    log "Nginx configured"
}

setup_frontend() {
    log "Setting up frontend"
    mkdir -p "$FRONTEND_DIR"
    chown -R ubuntu:ubuntu "$FRONTEND_DIR"

    sudo -u ubuntu bash << FRONTENDSETUP
cd $FRONTEND_DIR
[ ! -d "$APP_DIR" ] && git clone https://github.com/Kokoro-Doctor/frontend.git "$APP_DIR" || (cd "$APP_DIR" && git pull)
cd "$APP_DIR"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
npm install
FRONTENDSETUP
}

start_frontend() {
    log "Starting frontend"
    sudo -u ubuntu bash << STARTFRONT
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
export PATH=\$HOME/.nvm/versions/node/v18/bin:\$PATH
cd "$APP_DIR"
pm2 delete expo-app 2>/dev/null || true
pm2 start "npx expo start --web --port 8081" --name expo-app
pm2 save
STARTFRONT
}

setup_rag() {
    log "Setting up RAG backend"
    apt-get install -y nfs-common python3-venv python3-pip
    
    # EFS mount
    mkdir -p /mnt/efs
    mount -t nfs4 -o nfsvers=4.1 fs-071d25ce411b23a83.efs.ap-south-1.amazonaws.com:/ /mnt/efs 2>/dev/null || true
    grep -q "fs-071d25ce411b23a83" /etc/fstab || \
        echo "fs-071d25ce411b23a83.efs.ap-south-1.amazonaws.com:/ /mnt/efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0" >> /etc/fstab

    mkdir -p "$RAG_DIR"
    chown -R ubuntu:ubuntu "$RAG_DIR"

    sudo -u ubuntu bash << RAGSETUP
cd $RAG_DIR
[ ! -d .git ] && git clone https://github.com/Kokoro-Doctor/rag . || git pull
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip list | grep -E "uvicorn|fastapi" || pip install uvicorn fastapi
deactivate
RAGSETUP
}

start_rag() {
    log "Starting RAG backend"
    sudo -u ubuntu bash << STARTRAG
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
export PATH=\$HOME/.nvm/versions/node/v18/bin:\$PATH
cd $RAG_DIR
[ ! -f venv/bin/python ] && { echo "venv missing"; exit 1; }
pm2 delete rag-backend 2>/dev/null || true
pm2 start venv/bin/python --name rag-backend --interpreter none -- -m uvicorn app:app --host 0.0.0.0 --port 8000
pm2 save
STARTRAG
    sleep 2
    sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; pm2 list'
}

setup_ollama() {
    log "Installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh

    cat > /etc/systemd/system/ollama.service << 'OLLAMASVC'
[Unit]
Description=Ollama Service
After=network-online.target
[Service]
ExecStart=/usr/local/bin/ollama serve
User=root
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
OLLAMASVC

    systemctl daemon-reload
    systemctl enable ollama
    systemctl start ollama
    
    log "Waiting for Ollama"
    local retries=15
    while [ $retries -gt 0 ]; do
        curl -s http://localhost:11434 >/dev/null && { log "Ollama ready"; break; }
        sleep 5
        ((retries--))
        [ $retries -eq 7 ] && systemctl restart ollama
    done
    
    log "Pulling llama3 model"
    ollama pull llama3
}

create_healthcheck() {
    cat > /home/ubuntu/check.sh << 'HEALTH'
#!/bin/bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export PATH=$HOME/.nvm/versions/node/v18/bin:$PATH

echo "=== PM2 ==="
pm2 list
echo -e "\n=== Ports ==="
for port in 8081 8000 11434; do
    echo -n "Port $port: "
    curl -s http://localhost:$port >/dev/null && echo "✓" || echo "✗"
done
echo -e "\n=== Services ==="
systemctl status nginx ollama --no-pager | grep Active
HEALTH
    chmod +x /home/ubuntu/check.sh
    chown ubuntu:ubuntu /home/ubuntu/check.sh
}

# === MAIN ===

echo "========================================"
echo "🚀 Kokoro Doctor Deployment"
echo "========================================"

# Check if on AWS
if curl -s http://169.254.169.254/latest/meta-data/ &>/dev/null; then
    wait_eip
fi

setup_env
apt-get update -y
apt-get install -y git curl build-essential

install_node
install_pm2

log "=== STAGE 1: Nginx & Frontend ==="
setup_nginx
setup_frontend
start_frontend
log "Frontend live at https://$DOMAIN"

log "=== STAGE 2: RAG Backend ==="
setup_rag
start_rag

log "=== STAGE 3: Ollama ==="
setup_ollama

# Final save
sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; pm2 save'

create_healthcheck

echo ""
echo "========================================"
echo "✅ Deployment Complete!"
echo "========================================"
echo "🌐 Site: https://$DOMAIN"
echo "📊 Check: ./check.sh"
echo "📋 Logs: pm2 logs"
echo "========================================"

sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; pm2 list'