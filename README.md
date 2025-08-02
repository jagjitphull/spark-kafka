A comprehensive and easy-to-follow document for setting up and testing a 3-node Kafka cluster (KRaft mode), suitable for both reference and training.
-----

# Setting Up and Testing a 3-Node Apache Kafka Cluster (KRaft Mode)

## Version: Kafka 4.0.0

## Date: August 2, 2025

## Author: Jagjit Phull (JP)

-----

## Table of Contents

1.  Introduction
2.  Prerequisites
3.  Cluster Node Information
4.  Step-by-Step Installation & Configuration
    1.  Preparation (On All Nodes)
        1.  System Update & Java Installation
        2.  Configure `JAVA_HOME`
        3.  Configure Hostnames (`/etc/hosts`)
        4.  Create Kafka User & Directories
        5.  Download & Extract Kafka
    2.  Kafka Configuration (`server.properties` - Per Node)
    3.  Generate KRaft Cluster ID (On One Node Only)
    4.  Format KRaft Storage (On All Nodes)
    5.  Create Systemd Service (On All Nodes)
    6.  Enable & Start Kafka (On All Nodes)
5.  Testing the Kafka Cluster
    1.  Verify Connectivity to All Brokers
    2.  Create a Test Topic
    3.  Verify Topic Creation and Replication
    4.  Produce Messages to the Topic
    5.  Consume Messages from the Topic
    6.  Test Broker Fault Tolerance (Optional)
6.  Troubleshooting Common Issues
7.  Conclusion

-----

## 1\. Introduction

This document provides a detailed, step-by-step guide for setting up a highly available, 3-node Apache Kafka cluster using the modern KRaft (Kafka Raft) consensus protocol. This setup eliminates the need for an external ZooKeeper ensemble, simplifying deployment and management. The guide also includes comprehensive testing procedures to ensure the cluster's functionality and resilience.

This document is suitable for system administrators, developers, and anyone looking to deploy or learn about Kafka in a clustered environment.

## 2\. Prerequisites

Before starting the installation, ensure the following prerequisites are met on **all three server machines** that will host Kafka:

  * **Operating System:** Ubuntu Server 24.04.2 LTS (or similar Debian-based Linux distribution).
  * **Java Development Kit (JDK):** OpenJDK 17 or later.
  * **Network Connectivity:** All three nodes must be able to communicate with each other via their hostnames or IP addresses.
  * **Sufficient Resources:**
      * Minimum 2 GB RAM (4 GB recommended for production).
      * Minimum 2 CPU Cores.
      * Adequate disk space for Kafka logs and data.
  * **User Permissions:** `sudo` access for installation steps.

## 3\. Cluster Node Information

For this guide, we'll use the following naming convention and assume corresponding IP addresses. **Replace these example IPs with your actual server IPs.**

| Node Name | Role                 | IP Address (Example) | KRaft Node ID | Client Port (PLAINTEXT) | Controller Port (CONTROLLER) |
| :-------- | :------------------- | :------------------- | :------------ | :---------------------- | :--------------------------- |
| `kafka1`  | Broker & Controller  | `192.168.1.199`      | `1`           | `9092`                  | `9093`                       |
| `kafka2`  | Broker & Controller  | `192.168.1.200`      | `2`           | `9092`                  | `9093`                       |
| `kafka3`  | Broker & Controller  | `192.168.1.201`      | `3`           | `9092`                  | `9093`                       |

-----

## 4\. Step-by-Step Installation & Configuration

### 4.1. Preparation (On All Nodes: `kafka1`, `kafka2`, `kafka3`)

Perform these steps identically on all three machines.

#### 4.1.1. System Update & Java Installation

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y openjdk-17-jdk wget tar
```

#### 4.1.2. Configure `JAVA_HOME` (System-Wide)

This ensures all processes correctly find the Java installation.

1.  **Find your Java 17 path:**
    ```bash
    readlink -f /usr/bin/java | sed "s:bin/java::"
    # Expected output: /usr/lib/jvm/java-17-openjdk-amd64/
    ```
2.  **Edit `/etc/environment`:**
    ```bash
    sudo nano /etc/environment
    ```
3.  **Add the following lines** to the end of the file (adjust path if different):
    ```
    JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
    PATH="$PATH:$JAVA_HOME/bin"
    ```
4.  **Save and exit** (Ctrl+O, Enter, Ctrl+X in nano).
5.  **Apply changes** (for current session) and **verify**:
    ```bash
    source /etc/environment
    echo $JAVA_HOME
    java -version
    ```
    *(For changes to fully propagate, a server reboot or logging out and back in is recommended.)*

#### 4.1.3. Configure Hostnames (`/etc/hosts`)

This is **CRUCIAL** for inter-node communication. Each node must be able to resolve the hostnames of all other nodes.

1.  **Edit `/etc/hosts` on EACH node:**
    ```bash
    sudo nano /etc/hosts
    ```
2.  **Add entries for all Kafka nodes** at the end of the file, replacing example IPs with your actual IPs:
    ```
    # Kafka Cluster Nodes
    192.168.1.199   kafka1
    192.168.1.200   kafka2
    192.168.1.201   kafka3
    ```
3.  **Save and exit.**
4.  **Test connectivity from each node to others:**
    ```bash
    ping kafka1
    ping kafka2
    ping kafka3
    ```
    (Ensure all pings are successful from each machine)

#### 4.1.4. Create Kafka User & Directories

Create a dedicated user and necessary directories for Kafka.

```bash
KAFKA_USER="kafka"
INSTALL_DIR="/usr/local/kafka"
LOG_DIR="$INSTALL_DIR/logs"
DATA_DIR="$INSTALL_DIR/data" # For KRaft metadata and cluster logs

sudo useradd -m -s /bin/bash $KAFKA_USER
sudo mkdir -p $INSTALL_DIR
sudo mkdir -p $LOG_DIR
sudo mkdir -p $DATA_DIR
sudo chown -R $KAFKA_USER:$KAFKA_USER $INSTALL_DIR
sudo chown -R $KAFKA_USER:$KAFKA_USER $LOG_DIR
sudo chown -R $KAFKA_USER:$KAFKA_USER $DATA_DIR
```

#### 4.1.5. Download & Extract Kafka

Download the Kafka distribution and place it in the installation directory.

```bash
KAFKA_VERSION="4.0.0"
SCALA_VERSION="2.13" # Or 2.12 depending on the Kafka package you choose
DOWNLOAD_URL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"

wget "$DOWNLOAD_URL" -O /tmp/kafka.tgz
tar -xzf /tmp/kafka.tgz -C /tmp/
sudo mv /tmp/kafka_${SCALA_VERSION}-${KAFKA_VERSION}/* $INSTALL_DIR/
sudo chown -R $KAFKA_USER:$KAFKA_USER $INSTALL_DIR
```

### 4.2. Kafka Configuration (`server.properties` - Per Node)

Each node needs its own `server.properties` file. **Pay close attention to the `node.id`, `listeners`, and `advertised.listeners` specific to each node.**

**On `kafka1`:**

```bash
sudo tee /usr/local/kafka/config/server.properties > /dev/null <<EOF
# KRaft Node Configuration
process.roles=broker,controller
node.id=1 # Unique ID for this node (1, 2, or 3)

# Controller Quorum (All controller nodes in the cluster)
controller.quorum.voters=1@kafka1:9093,2@kafka2:9093,3@kafka3:9093

# Listeners for Clients and Inter-Broker Communication
listeners=PLAINTEXT://kafka1:9092,CONTROLLER://kafka1:9093
advertised.listeners=PLAINTEXT://kafka1:9092,CONTROLLER://kafka1:9093
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT

# Log Directories for Topic Data
log.dirs=/usr/local/kafka/logs
log.retention.hours=168
log.segment.bytes=1073741824
num.recovery.threads.per.data.dir=1

# Data Directory for KRaft Metadata Logs
metadata.log.dir=/usr/local/kafka/data
EOF
sudo chown kafka:kafka /usr/local/kafka/config/server.properties
```

**On `kafka2`:**

```bash
sudo tee /usr/local/kafka/config/server.properties > /dev/null <<EOF
# KRaft Node Configuration
process.roles=broker,controller
node.id=2 # Unique ID for this node (1, 2, or 3)

# Controller Quorum (All controller nodes in the cluster)
controller.quorum.voters=1@kafka1:9093,2@kafka2:9093,3@kafka3:9093

# Listeners for Clients and Inter-Broker Communication
listeners=PLAINTEXT://kafka2:9092,CONTROLLER://kafka2:9093
advertised.listeners=PLAINTEXT://kafka2:9092,CONTROLLER://kafka2:9093
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT

# Log Directories for Topic Data
log.dirs=/usr/local/kafka/logs
log.retention.hours=168
log.segment.bytes=1073741824
num.recovery.threads.per.data.dir=1

# Data Directory for KRaft Metadata Logs
metadata.log.dir=/usr/local/kafka/data
EOF
sudo chown kafka:kafka /usr/local/kafka/config/server.properties
```

**On `kafka3`:**

```bash
sudo tee /usr/local/kafka/config/server.properties > /dev/null <<EOF
# KRaft Node Configuration
process.roles=broker,controller
node.id=3 # Unique ID for this node (1, 2, or 3)

# Controller Quorum (All controller nodes in the cluster)
controller.quorum.voters=1@kafka1:9093,2@kafka2:9093,3@kafka3:9093

# Listeners for Clients and Inter-Broker Communication
listeners=PLAINTEXT://kafka3:9092,CONTROLLER://kafka3:9093
advertised.listeners=PLAINTEXT://kafka3:9092,CONTROLLER://kafka3:9093
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT

# Log Directories for Topic Data
log.dirs=/usr/local/kafka/logs
log.retention.hours=168
log.segment.bytes=1073741824
num.recovery.threads.per.data.dir=1

# Data Directory for KRaft Metadata Logs
metadata.log.dir=/usr/local/kafka/data
EOF
sudo chown kafka:kafka /usr/local/kafka/config/server.properties
```

### 4.3. Generate KRaft Cluster ID (ONLY on ONE of the nodes, e.g., `kafka1`)

This unique ID identifies your entire Kafka cluster. You generate it once.

**On `kafka1` ONLY:**

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-storage.sh random-uuid
```

**Copy the output (e.g., `0RVdbTokSjie5Ydhm4j7aw`). This is your `CLUSTER_ID`.** You will use this same ID in the next step on all nodes.

### 4.4. Format KRaft Storage (On All Nodes: `kafka1`, `kafka2`, `kafka3`)

Use the `CLUSTER_ID` obtained above to format the storage directories on *all* nodes. **Ensure you replace `YOUR_CLUSTER_ID` with the actual ID you generated.**

**On `kafka1` (replace `YOUR_CLUSTER_ID`):**

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-storage.sh format \
  --cluster-id "YOUR_CLUSTER_ID" \
  --config /usr/local/kafka/config/server.properties \
  --ignore-formatted
```

**On `kafka2` (replace `YOUR_CLUSTER_ID`):**

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-storage.sh format \
  --cluster-id "YOUR_CLUSTER_ID" \
  --config /usr/local/kafka/config/server.properties \
  --ignore-formatted
```

**On `kafka3` (replace `YOUR_CLUSTER_ID`):**

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-storage.sh format \
  --cluster-id "YOUR_CLUSTER_ID" \
  --config /usr/local/kafka/config/server.properties \
  --ignore-formatted
```

### 4.5. Create Systemd Service (On All Nodes: `kafka1`, `kafka2`, `kafka3`)

This allows you to manage the Kafka broker as a system service.

```bash
sudo tee /etc/systemd/system/kafka.service > /dev/null <<EOF
[Unit]
Description=Apache Kafka 4.0 Broker (KRaft Mode)
Documentation=https://kafka.apache.org/documentation/
Wants=network-online.target
After=network-online.target

[Service]
User=kafka
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" # Ensure this path is correct
ExecStart=/usr/local/kafka/bin/kafka-server-start.sh /usr/local/kafka/config/server.properties
ExecStop=/usr/local/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

### 4.6. Enable & Start Kafka (On All Nodes: `kafka1`, `kafka2`, `kafka3`)

Start the Kafka service on all nodes. It's generally good practice to start them one after another, allowing a brief moment for initial setup.

```bash
sudo systemctl enable kafka
sudo systemctl start kafka
```

-----

## 5\. Testing the Kafka Cluster

After all nodes are started, wait a minute or two for them to initialize and form the quorum. Then, proceed with these tests.

### 5.1. Verify Connectivity to All Brokers

Run these commands from any of your Kafka nodes (e.g., `kafka1`).

```bash
echo "Checking kafka1..."
sudo -u kafka /usr/local/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server kafka1:9092

echo "Checking kafka2..."
sudo -u kafka /usr/local/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server kafka2:9092

echo "Checking kafka3..."
sudo -u kafka /usr/local/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server kafka3:9092
```

**Expected Output:** For each, you should see output listing the `BrokerId`, `Host`, `Port`, and supported API versions (e.g., `kafka1:9092 (id: 1 rack: null isFenced: false) -> (...)`). This confirms all individual brokers are responsive.

### 5.2. Create a Test Topic

This topic will be replicated across your 3-node cluster.

Run this command from any of your Kafka nodes (e.g., `kafka1`):

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-topics.sh --create \
  --topic my_cluster_test_topic \
  --partitions 3 \
  --replication-factor 3 \
  --bootstrap-server kafka1:9092 # Use any broker's PLAINTEXT address
```

**Expected Output:**
`Created topic my_cluster_test_topic.`

### 5.3. Verify Topic Creation and Replication

Confirm the topic structure and its distribution across brokers.

Run this command from any of your Kafka nodes (e.g., `kafka1`):

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-topics.sh --describe \
  --topic my_cluster_test_topic \
  --bootstrap-server kafka1:9092
```

**Expected Output:**

```
Topic: my_cluster_test_topic    TopicId: <some-uuid>    PartitionCount: 3   ReplicationFactor: 3    Configs:
    Partition: 0    Leader: 1   Replicas: 1,2,3 Isr: 1,2,3
    Partition: 1    Leader: 2   Replicas: 2,3,1 Isr: 2,3,1
    Partition: 2    Leader: 3   Replicas: 3,1,2 Isr: 3,1,2
```

  * `PartitionCount: 3`, `ReplicationFactor: 3`: Confirms your settings.
  * `Leader:`: The broker currently serving read/write requests for that partition.
  * `Replicas:`: All brokers holding a copy of that partition's data (should include 1, 2, and 3).
  * `Isr:` (In-Sync Replicas): Replicas that are fully synchronized with the leader. Ideally, this should match `Replicas`.

### 5.4. Produce Messages to the Topic

Send some test messages to ensure data can be written to the cluster.

Run this command from any of your Kafka nodes (e.g., `kafka1`):

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-console-producer.sh \
  --topic my_cluster_test_topic \
  --bootstrap-server kafka1:9092
```

The producer will show a `>` prompt. Type your messages, pressing **Enter** after each:

```
>Hello from Kafka Cluster!
>This is my first message.
>Testing 3 node setup.
>Another message.
```

Press **Ctrl+C** to exit the producer. Note that the producer typically does not provide confirmation messages for each line; it simply sends the data.

### 5.5. Consume Messages from the Topic

Verify that messages are correctly stored and can be read by a consumer.

Open a **NEW terminal window/SSH session** and run this command on a **DIFFERENT Kafka node** (e.g., `kafka2`):

```bash
sudo -u kafka /usr/local/kafka/bin/kafka-console-consumer.sh \
  --topic my_cluster_test_topic \
  --bootstrap-server kafka1:9092 \
  --from-beginning
```

**Expected Output:** You should see all the messages you produced:

```
Hello from Kafka Cluster!
This is my first message.
Testing 3 node setup.
Another message.
```

This confirms end-to-end message flow through your cluster. Press **Ctrl+C** to exit the consumer.

### 5.6. Test Broker Fault Tolerance (Optional but Highly Recommended)

This test confirms your cluster's high availability.

1.  **Stop one broker:** On one of your Kafka nodes (e.g., `kafka2`), stop the Kafka service:

    ```bash
    sudo systemctl stop kafka
    ```

      * **Observe:** Any active consumers might temporarily pause or show warnings, but should eventually resume.

2.  **Produce more messages:** Go back to your producer terminal (or start a new one) and produce a few more messages, targeting any *remaining* active broker (e.g., `kafka1`).

    ```bash
    sudo -u kafka /usr/local/kafka/bin/kafka-console-producer.sh \
      --topic my_cluster_test_topic \
      --bootstrap-server kafka1:9092
    ```

    Type some messages like:

    ```
    Message while kafka2 is down.
    Cluster still working!
    ```

    Press Ctrl+C.

3.  **Check topic describe again:**

    ```bash
    sudo -u kafka /usr/local/kafka/bin/kafka-topics.sh --describe \
      --topic my_cluster_test_topic \
      --bootstrap-server kafka1:9092
    ```

    **Expected:** For partitions where `kafka2` was a leader or replica, you should see `kafka2` absent from the `Isr` list, and if `kafka2` was a leader, a new leader should have been elected (from `kafka1` or `kafka3`).

4.  **Start the stopped broker:** On `kafka2`, start the Kafka service again:

    ```bash
    sudo systemctl start kafka
    ```

5.  **Observe and re-verify:**

      * Check `sudo systemctl status kafka` on `kafka2` to confirm it's running.
      * Wait a minute or two for it to fully sync.
      * Run `kafka-topics.sh --describe` again. You should see `kafka2` return to the `Isr` for its partitions, indicating it's back in sync.
      * New messages produced will now leverage `kafka2` again.

-----

## 6\. Troubleshooting Common Issues

  * **`Exception in thread "main" java.lang.IllegalArgumentException: No colon following port could be found.`**

      * **Cause:** Incorrect formatting in `listeners`, `advertised.listeners`, or `controller.quorum.voters`. Usually, missing a colon (`:`) or having extra spaces.
      * **Fix:** Double-check these properties in `server.properties`. Ensure `hostname:port` format (e.g., `PLAINTEXT://kafka1:9092`) is strictly followed, and no hidden characters are present. Verify `controller.quorum.voters` uses `nodeId@hostname:port`.

  * **`Connection to node -1 (...) could not be established.`**

      * **Cause:** The client (or broker trying to connect to another broker) cannot reach the target host and port.
      * **Fixes:**
          * **Hostname Resolution:** Ensure `/etc/hosts` on *all* machines correctly maps hostnames (`kafka1`, `kafka2`, `kafka3`) to their respective IP addresses. Test with `ping hostname`.
          * **Kafka Service Status:** Verify the Kafka service is running on the target node (`sudo systemctl status kafka`).
          * **Listeners Configuration:** Check `listeners` and especially `advertised.listeners` in `server.properties`. `advertised.listeners` must be an address reachable by clients.
          * **Firewall:** Check `ufw` or cloud security groups (`sudo ufw status`) to ensure ports `9092` (client) and `9093` (controller) are open for TCP traffic.
          * **Port Listening:** Use `sudo netstat -tulnp | grep 9092` (on the target machine) to confirm Kafka is listening on the expected port and IP.

  * **Kafka service fails to start.**

      * **Cause:** Often configuration errors or corrupted KRaft metadata.
      * **Fixes:**
          * Check `sudo journalctl -u kafka.service -f` for detailed error messages.
          * Review `/usr/local/kafka/logs/server.log` for any `ERROR` or `WARN` messages during startup.
          * If `metadata.log.dir` (`/usr/local/kafka/data`) contents are corrupted from previous failed attempts, stop Kafka, remove contents of `/usr/local/kafka/data` and `/usr/local/kafka/logs` (`sudo rm -rf /usr/local/kafka/data/* /usr/local/kafka/logs/*`), then re-run the `kafka-storage.sh format` command (with the *same* Cluster ID) and restart Kafka.

-----

## 7\. Conclusion

You have successfully set up and tested a 3-node Apache Kafka cluster using KRaft mode. This resilient setup provides high availability for your messaging infrastructure. Remember to consult the official Apache Kafka documentation for more advanced configurations, optimizations, and security best practices for production deployments.

-----
