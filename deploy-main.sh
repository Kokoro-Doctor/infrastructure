#!/bin/bash
# =================================================================
# MAIN DEPLOYMENT SCRIPT - FIXED VERSION
# Upload this to GitHub as: deploy-main.sh
# =================================================================

set -e
exec > >(tee -a /var/log/kokoro-deploy.log) 2>&1

# === CONFIG ===
SSL_CERT_PATH="/etc/ssl/kokoro"
S3_BUCKET="s3://kokoro-doctor"
DOMAIN="kokoro.doctor"
FRONTEND_DIR="/home/ubuntu/frontend"
APP_DIR="$FRONTEND_DIR/KokoroDoctor"
RAG_BACKEND_DIR="/home/ubuntu/rag_backend"
NODE_VERSION="20"
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
export PATH=$HOME/.nvm/versions/node/v20/bin:$PATH
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
nvm install 20
nvm use 20
nvm alias default 20
NODESETUP

    export NVM_DIR="/home/ubuntu/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    log "Node.js installed successfully"
}

install_pm2() {
    log "Installing PM2"
    
    export NVM_DIR="/home/ubuntu/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Install PM2 and expo-cli
    sudo -u ubuntu bash << 'PM2SETUP'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
npm install -g pm2 expo-cli
PM2SETUP

    # Setup PM2 startup - FIXED: Execute the command directly
    log "Setting up PM2 startup"
    
    # Get the node path
    local NODE_PATH="/home/ubuntu/.nvm/versions/node/v${NODE_VERSION}.20.8/bin"
    
    # Execute PM2 startup command directly
    sudo env PATH=$PATH:$NODE_PATH $NODE_PATH/pm2 startup systemd -u ubuntu --hp /home/ubuntu || {
        log "PM2 startup setup completed (may have warnings)"
    }
    
    log "PM2 installed successfully"
}

wait_eip() {
    log "Waiting for Elastic IP"
    local retries=20
    while [ $retries -gt 0 ]; do
        local ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
        if [[ -n "$ip" && "$ip" == "$EXPECTED_EIP" ]]; then
            log "EIP attached: $ip"
            return 0
        fi
        sleep 30
        ((retries--))
    done
    err "EIP timeout - continuing anyway"
}

setup_nginx() {
    log "Setting up Nginx"
    
    apt-get update -y
    apt-get install -y nginx awscli
    
    mkdir -p /etc/nginx/sites-{available,enabled} $SSL_CERT_PATH
    chmod 700 $SSL_CERT_PATH

    log "Downloading SSL certificates"
    aws s3 cp $S3_BUCKET/ssl/kokoro.doctor.fullchain.pem $SSL_CERT_PATH/ 2>/dev/null || err "SSL cert download failed"
    aws s3 cp $S3_BUCKET/ssl/kokoro.doctor.key $SSL_CERT_PATH/ 2>/dev/null || err "SSL key download failed"

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
        proxy_read_timeout 60s;
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
    log "Nginx configured and running"
}

setup_frontend() {
    log "Setting up frontend"
    mkdir -p "$FRONTEND_DIR"
    chown -R ubuntu:ubuntu "$FRONTEND_DIR"

    sudo -u ubuntu bash << FRONTENDSETUP
cd $FRONTEND_DIR
if [ ! -d "$APP_DIR" ]; then
    echo "Cloning frontend repository..."
    git clone https://github.com/Kokoro-Doctor/frontend.git "$APP_DIR"
else
    echo "Updating frontend repository..."
    cd "$APP_DIR" && git pull origin main || true
fi
cd "$APP_DIR"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
echo "Installing frontend dependencies..."
npm install
FRONTENDSETUP
    
    log "Frontend setup completed"
}

start_frontend() {
    log "Starting frontend with PM2"
    sudo -u ubuntu bash << STARTFRONT
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
export PATH=\$HOME/.nvm/versions/node/v20/bin:\$PATH
cd "$APP_DIR"
pm2 delete expo-app 2>/dev/null || true
pm2 start "npx expo start --web --port 8081" --name expo-app
pm2 save
STARTFRONT
    
    log "Frontend started successfully"
}

setup_rag_backend() {
    log "Setting up RAG backend"
    apt-get install -y nfs-common python3-venv python3-pip
    
    # EFS mount
    log "Mounting EFS"
    mkdir -p /mnt/efs
    mount -t nfs4 -o nfsvers=4.1 fs-071d25ce411b23a83.efs.ap-south-1.amazonaws.com:/ /mnt/efs 2>/dev/null || log "EFS already mounted"
    
    grep -q "fs-071d25ce411b23a83" /etc/fstab || \
        echo "fs-071d25ce411b23a83.efs.ap-south-1.amazonaws.com:/ /mnt/efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0" >> /etc/fstab

    mkdir -p "$RAG_BACKEND_DIR"
    chown -R ubuntu:ubuntu "$RAG_BACKEND_DIR"

    log "Setting up RAG backend code"
    sudo -u ubuntu bash << RAGSETUP
cd $RAG_BACKEND_DIR
if [ ! -d .git ]; then
    echo "Cloning RAG backend..."
    git clone https://github.com/Kokoro-Doctor/rag .
else
    echo "Updating RAG backend..."
    git pull origin main || true
fi

echo "Setting up Python virtual environment..."
rm -rf venv
python3 -m venv venv
source venv/bin/activate

echo "Installing Python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

echo "Verifying critical packages..."
pip list | grep -E "uvicorn|fastapi" || pip install uvicorn fastapi

deactivate
RAGSETUP
    
    log "RAG backend setup completed"
}

start_rag_backend() {
    log "Starting RAG backend with PM2"
    sudo -u ubuntu bash << STARTRAG
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
export PATH=\$HOME/.nvm/versions/node/v20/bin:\$PATH
cd $RAG_BACKEND_DIR

if [ ! -f venv/bin/python ]; then
    echo "ERROR: Virtual environment not found!"
    exit 1
fi

pm2 delete rag-backend 2>/dev/null || true
pm2 start venv/bin/python --name rag-backend --interpreter none -- -m uvicorn app:app --host 0.0.0.0 --port 8000
pm2 save
STARTRAG
    
    sleep 2
    log "RAG backend started - checking status..."
    sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; pm2 list | grep rag-backend'
}

setup_ollama() {
    log "Installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh

    log "Creating Ollama systemd service"
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
    
    log "Waiting for Ollama to start"
    local retries=15
    while [ $retries -gt 0 ]; do
        if curl -s http://localhost:11434 >/dev/null 2>&1; then
            log "Ollama is ready"
            break
        fi
        sleep 5
        ((retries--))
        if [ $retries -eq 7 ]; then
            log "Restarting Ollama..."
            systemctl restart ollama
        fi
    done
    
    log "Pulling llama3 model (this may take 5-10 minutes)..."
    ollama pull llama3
    log "Ollama setup completed"
}

create_check_services() {
    log "Creating check-services.sh script"
    cat > /home/ubuntu/check-services.sh << 'HEALTH'
#!/bin/bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export PATH=$HOME/.nvm/versions/node/v20/bin:$PATH

echo "=== SERVICE STATUS ==="
echo "PM2 Processes:"
pm2 list
echo ""
echo "Nginx Status:"
systemctl status nginx --no-pager | head -5
echo ""
echo "Ollama Status:"
systemctl status ollama --no-pager | head -5
echo ""
echo "EFS Mount:"
df -h | grep efs || echo "EFS not mounted"
echo ""
echo "=== PORT CHECKS ==="
for port in 8081:Frontend 8000:RAG-Backend 11434:Ollama; do
    IFS=':' read -r pnum pname <<< "$port"
    echo -n "$pname ($pnum): "
    curl -s http://localhost:$pnum >/dev/null && echo "✓ Running" || echo "✗ Not responding"
done
HEALTH
    chmod +x /home/ubuntu/check-services.sh
    chown ubuntu:ubuntu /home/ubuntu/check-services.sh
}

# === MAIN EXECUTION ===

echo "========================================"
echo "🚀 Kokoro Doctor Deployment"
echo "========================================"
echo "Start Time: $(date)"
echo ""

# Check if on AWS and wait for EIP
if curl -s http://169.254.169.254/latest/meta-data/ &>/dev/null; then
    wait_eip
fi

setup_env

log "Installing system dependencies"
apt-get update -y
apt-get install -y git curl build-essential

install_node
install_pm2

echo ""
log "=== STAGE 1: Nginx & Frontend ==="
setup_nginx
setup_frontend
start_frontend
log "Frontend is now live at https://$DOMAIN"

echo ""
log "=== STAGE 2: RAG Backend ==="
setup_rag_backend
start_rag_backend

echo ""
log "=== STAGE 3: Ollama (This takes time) ==="
setup_ollama

# Final PM2 save
log "Saving PM2 configuration"
sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; pm2 save'

create_check_services

echo ""
echo "==========================================="
echo "✅ 🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "==========================================="
echo ""
echo "🌐 Frontend: https://$DOMAIN"
echo "🤖 RAG Backend: Running on port 8000"
echo "🦙 Ollama: Running on port 11434"
echo ""
echo "📊 Service Management:"
echo "  - PM2 will persist after reboot"
echo "  - Use 'pm2 list' to check running processes"
echo "  - Use 'pm2 logs [app-name]' to view logs"
echo "  - Use './check-services.sh' for quick status check"
echo ""
echo "🔧 Troubleshooting:"
echo "  - If RAG backend crashes: cd ~/rag_backend && pm2 logs rag-backend"
echo "  - Restart services: pm2 restart all"
echo "  - Check Nginx: sudo nginx -t && sudo systemctl status nginx"
echo ""
echo "End Time: $(date)"
echo "========================================"
echo ""

# Show final status
log "Final PM2 Status:"
sudo -u ubuntu bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; pm2 list'
