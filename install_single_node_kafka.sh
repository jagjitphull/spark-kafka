#!/usr/bin/env bash
set -euo pipefail

# === Configuration Variables ===
# These can be customized if needed
KAFKA_VERSION="4.0.0"
SCALA_VERSION="2.13" # Or 2.12 based on the Kafka package
INSTALL_DIR="/usr/local/kafka"
KAFKA_USER="kafka"
KAFKA_GROUP="kafka"
KAFKA_PORT="9092"
KAFKA_CONTROLLER_PORT="9093"
JAVA_VERSION="17"
JAVA_PACKAGE="openjdk-${JAVA_VERSION}-jdk" # For apt install

DOWNLOAD_URL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"

# === Function for logging ===
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - INFO - $1"
}

warn() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - WARN - $1" >&2
}

error() {
    echo "$(date +'%Y-%m-%m %H:%M:%S') - ERROR - $1" >&2
    exit 1
}

# === Pre-flight Checks ===
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root or with sudo."
fi

if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet kafka; then
        warn "Kafka service is already running. Stopping it for re-installation."
        systemctl stop kafka || true # Stop, but don't fail if it's not actually running
    fi
    if systemctl is-enabled --quiet kafka; then
        warn "Kafka service is already enabled. Disabling it."
        systemctl disable kafka || true
    fi
    # Clean up old service file if it exists
    if [ -f "/etc/systemd/system/kafka.service" ]; then
        warn "Removing existing kafka.service file."
        rm -f "/etc/systemd/system/kafka.service"
        systemctl daemon-reload
    fi
fi

if [ -d "$INSTALL_DIR" ]; then
    warn "Existing Kafka installation found at $INSTALL_DIR. Backing it up."
    mv "$INSTALL_DIR" "${INSTALL_DIR}_backup_$(date +%s)"
fi

if id -u "$KAFKA_USER" >/dev/null 2>&1; then
    warn "Kafka user '$KAFKA_USER' already exists."
else
    log "Creating Kafka user '$KAFKA_USER'."
    useradd -r -m -s /bin/bash "$KAFKA_USER" || error "Failed to create user '$KAFKA_USER'."
fi

# === Step 1: Update System and Install Prerequisites ===
log "Updating system packages and installing OpenJDK ${JAVA_VERSION} and tools."
apt update || error "Failed to update apt cache."
apt install -y "$JAVA_PACKAGE" wget tar procps net-tools || error "Failed to install prerequisites."

# === Step 2: Configure JAVA_HOME system-wide ===
log "Configuring JAVA_HOME system-wide."
JAVA_HOME_PATH=$(readlink -f /usr/bin/java | sed "s:bin/java::")
if [ -z "$JAVA_HOME_PATH" ]; then
    error "Could not determine JAVA_HOME path. Is Java installed correctly?"
fi

# Remove existing JAVA_HOME from /etc/environment if it points to an older version or is malformed
sed -i '/^JAVA_HOME=/d' /etc/environment
sed -i '/^PATH=".*:$JAVA_HOME\/bin"/d' /etc/environment

echo "JAVA_HOME=\"$JAVA_HOME_PATH\"" | tee -a /etc/environment >/dev/null
# Append to PATH, careful not to duplicate if it exists elsewhere in shell profiles
grep -q "PATH=\"\$PATH:\$JAVA_HOME/bin\"" /etc/environment || echo "PATH=\"\$PATH:\$JAVA_HOME/bin\"" | tee -a /etc/environment >/dev/null

source /etc/environment # Apply changes to current script environment

log "JAVA_HOME set to: $JAVA_HOME"
log "PATH includes: $PATH"

# Verify JAVA_HOME for the current script's environment
if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME" ]; then
    error "JAVA_HOME is not set or path is invalid after configuration. Cannot proceed."
fi

# === Step 3: Create Kafka Directories ===
log "Creating Kafka installation directories."
mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/logs" "$INSTALL_DIR/data" || error "Failed to create Kafka directories."
chown -R "$KAFKA_USER":"$KAFKA_GROUP" "$INSTALL_DIR" || error "Failed to set ownership for Kafka directories."

# === Step 4: Download and Extract Kafka ===
log "Downloading Kafka ${KAFKA_VERSION} from $DOWNLOAD_URL."
wget -q "$DOWNLOAD_URL" -O /tmp/kafka.tgz || error "Failed to download Kafka."

log "Extracting Kafka to $INSTALL_DIR."
TMP_EXTRACT="/tmp/kafka_extract"
rm -rf "$TMP_EXTRACT"
mkdir -p "$TMP_EXTRACT"
tar -xzf /tmp/kafka.tgz -C "$TMP_EXTRACT" || error "Failed to extract Kafka."

# Move contents, not the directory itself, to avoid double nesting
mv "$TMP_EXTRACT/kafka_${SCALA_VERSION}-${KAFKA_VERSION}"/* "$INSTALL_DIR/" || error "Failed to move Kafka files."
chown -R "$KAFKA_USER":"$KAFKA_GROUP" "$INSTALL_DIR" || error "Failed to set ownership for Kafka installation."
rm -rf "$TMP_EXTRACT" /tmp/kafka.tgz

# === Step 5: Configure KRaft server.properties ===
log "Configuring Kafka server.properties for single-node KRaft."

# Get the actual hostname for advertised listeners
# Note: 'hostname -f' gets FQDN, 'hostname -I' gets IP.
# Using 'hostname' for simplicity, assumes it resolves internally.
# For Docker/NAT, advertise the *external* IP/hostname.
HOST_ADDR=$(hostname) # Or use $(hostname -I | awk '{print $1}') for primary IP

if [ -z "$HOST_ADDR" ]; then
    warn "Could not determine hostname for advertised listeners. Using 'localhost'."
    HOST_ADDR="localhost"
fi

cat <<EOF | tee "$INSTALL_DIR/config/server.properties" > /dev/null
# KRaft Node Configuration for Single-Node Setup
process.roles=broker,controller

# Unique ID for this single node
node.id=1 

# Controller Quorum - Only this node
controller.quorum.voters=1@$HOST_ADDR:$KAFKA_CONTROLLER_PORT

# Listeners for Clients and Inter-Broker Communication
listeners=PLAINTEXT://:$KAFKA_PORT,CONTROLLER://:$KAFKA_CONTROLLER_PORT
advertised.listeners=PLAINTEXT://$HOST_ADDR:$KAFKA_PORT,CONTROLLER://$HOST_ADDR:$KAFKA_CONTROLLER_PORT
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT

# Log Directories for Topic Data
log.dirs=$INSTALL_DIR/logs
log.retention.hours=168
log.segment.bytes=1073741824
num.recovery.threads.per.data.dir=1

# Data Directory for KRaft Metadata Logs
metadata.log.dir=$INSTALL_DIR/data
EOF
chown "$KAFKA_USER":"$KAFKA_GROUP" "$INSTALL_DIR/config/server.properties" || error "Failed to set ownership for server.properties."

# === Step 6: Format KRaft Storage ===
log "Formatting KRaft storage."
# Generate Cluster ID
CLUSTER_ID=$(sudo -u "$KAFKA_USER" "$INSTALL_DIR/bin/kafka-storage.sh" random-uuid || error "Failed to generate Cluster ID.")
log "Generated Cluster ID: $CLUSTER_ID"

# Format storage
sudo -u "$KAFKA_USER" "$INSTALL_DIR/bin/kafka-storage.sh" format \
  --cluster-id "$CLUSTER_ID" \
  --config "$INSTALL_DIR/config/server.properties" \
  --ignore-formatted || error "Failed to format KRaft storage."

# === Step 7: Create systemd service for Kafka ===
log "Creating systemd service for Kafka."
cat <<EOF | tee /etc/systemd/system/kafka.service > /dev/null
[Unit]
Description=Apache Kafka ${KAFKA_VERSION} Broker (KRaft Mode)
Documentation=https://kafka.apache.org/documentation/
Wants=network-online.target
After=network-online.target

[Service]
User=${KAFKA_USER}
Group=${KAFKA_GROUP}
Environment="JAVA_HOME=${JAVA_HOME_PATH}" # Use the determined JAVA_HOME
ExecStart=${INSTALL_DIR}/bin/kafka-server-start.sh ${INSTALL_DIR}/config/server.properties
ExecStop=${INSTALL_DIR}/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536 # Recommended for Kafka

[Install]
WantedBy=multi-user.target
EOF

# === Step 8: Enable and Start Kafka ===
log "Reloading systemd, enabling and starting Kafka service."
systemctl daemon-reload || error "Failed to reload systemd daemon."
systemctl enable kafka || error "Failed to enable Kafka service."
systemctl start kafka || error "Failed to start Kafka service."

log "Checking Kafka service status (may take a moment to become active)."
sleep 10 # Give Kafka a moment to start up
systemctl status kafka --no-pager || warn "Kafka service might not be fully active yet. Check logs manually if issues persist."

log "🎉 Kafka ${KAFKA_VERSION} single-node installation and startup complete!"

# === Step 9: Quick Verification ===
log "Performing quick verification tests."
# Test if broker is reachable
log "Verifying Kafka broker API versions..."
sudo -u "$KAFKA_USER" "$INSTALL_DIR/bin/kafka-broker-api-versions.sh" --bootstrap-server "$HOST_ADDR:$KAFKA_PORT" || warn "Broker API version check failed. Check Kafka logs."

# Create a test topic
log "Creating a test topic 'training_topic'."
sudo -u "$KAFKA_USER" "$INSTALL_DIR/bin/kafka-topics.sh" --create \
  --topic training_topic \
  --partitions 1 \
  --replication-factor 1 \
  --bootstrap-server "$HOST_ADDR:$KAFKA_PORT" \
  --if-not-exists || warn "Failed to create 'training_topic'. It might already exist or broker is not ready."

# Describe the topic
log "Describing 'training_topic'."
sudo -u "$KAFKA_USER" "$INSTALL_DIR/bin/kafka-topics.sh" --describe \
  --topic training_topic \
  --bootstrap-server "$HOST_ADDR:$KAFKA_PORT" || warn "Failed to describe 'training_topic'."

log "Automated setup finished. Instruct your trainees to use the following commands for interactive testing:"
echo "---------------------------------------------------------------------------------------------------"
echo "To produce messages:"
echo "  sudo -u $KAFKA_USER $INSTALL_DIR/bin/kafka-console-producer.sh --topic training_topic --bootstrap-server $HOST_ADDR:$KAFKA_PORT"
echo "  (Type messages and press Enter. Press Ctrl+C to exit.)"
echo ""
echo "To consume messages:"
echo "  sudo -u $KAFKA_USER $INSTALL_DIR/bin/kafka-console-consumer.sh --topic training_topic --from-beginning --bootstrap-server $HOST_ADDR:$KAFKA_PORT"
echo "  (Press Ctrl+C to exit.)"
echo "---------------------------------------------------------------------------------------------------"
