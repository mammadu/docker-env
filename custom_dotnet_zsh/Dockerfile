FROM mcr.microsoft.com/dotnet/sdk:10.0

# Pin these for reproducible builds (default: latest releases).
ARG FZF_VERSION=latest
ARG TEALDEER_VERSION=latest
# Set to 0 for a faster, smaller build that skips man pages for preinstalled tools (ls, grep, ...).
ARG UNMINIMIZE=1
# Passwordless sudo for the non-root user. Set to 0 to leave sudo alone.
ARG ENABLE_SUDO=1

ENV LANG=C.UTF-8 \
    SHELL=/usr/bin/zsh

# Create any non-root user BEFORE this step; the script sets up root + the UID 1000 user
# ("ubuntu" in this image). Pass usernames explicitly to target others: `bash ... alice bob`
COPY install-shell-tools.sh /tmp/install-shell-tools.sh
RUN bash /tmp/install-shell-tools.sh && rm /tmp/install-shell-tools.sh

USER ubuntu
WORKDIR /home/ubuntu
CMD ["zsh"]