FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    openssh-client \
    sshpass \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install ansible

# Setup SSH directory
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Copy private key
COPY --chmod=600 id_ed25519 /root/.ssh/id_ed25519

# Disable strict host key checking for ansible
RUN echo "Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null" > /root/.ssh/config && \
    chmod 600 /root/.ssh/config

# Working directory for ansible files
WORKDIR /ansible

# Keep container running
CMD ["tail", "-f", "/dev/null"]
